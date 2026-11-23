"""PATRM video demo GUI (step 10.3): a burst of images streamed through the FPGA (or the ARM baseline) over Ethernet.

    python scripts/eth/video_gui.py
    python scripts/eth/video_gui.py --frames <png folder> --size 640x480 --transform sweep:-30:30

1. "Load board" programs the FPGA and starts results/hw/patrm_eth.elf (about 70 s; skip it if the board already runs
   the Ethernet application). Laptop Ethernet: 192.168.1.100/24, board 192.168.1.10.
2. Pick a folder of PNG/JPG frames, the size (W x H, W a multiple of 8) and the transform, then "Load frames".
3. "Play": every frame goes to the board, is warped by the engine (or by the ARM software baseline: Engine = ARM),
   and comes back. Input and output play side by side. Shown live: stream fps (frames per second through the board,
   one frame at a time), the time split of the last frame, CYCLES, and the model check: every output is compared with
   model/patrm.warp_gray in background processes ("bit-exact k of N"; any difference turns it red).
"Limit 60 fps" plays at video speed; without it the stream runs as fast as the link and engine allow.
On Stop a summary goes to results/eth/video_gui_<date>_<time>.txt.

Core (frames, transforms, link, check): scripts/eth/video_stream.py.
"""
import argparse
import datetime as dt
import sys
import threading
import time
import tkinter as tk
from collections import deque
from pathlib import Path
from tkinter import filedialog, ttk

from PIL import Image, ImageTk

sys.path.insert(0, str(Path(__file__).resolve().parent))
import eth_link as EL                          # noqa: E402
import video_stream as VS                      # noqa: E402

TRANSFORMS = ["spin", "sweep:-30:30", "zoom:0.8:1.3", "identity", "rot5", "rot15", "rot37", "rot90", "rot180",
              "mirror_cols", "mirror_rows", "scale0p8", "scale1p25", "combined"]
VIEW_W = 560                                   # each picture is shown at most this wide


class VideoGui:
    def __init__(self, root, a):
        self.root = root
        self.frames, self.files, self.bs = [], [], []
        self.size = None
        self.running = False
        self.worker = None
        self.lock = threading.Lock()
        self.latest = None                     # (k, src, out, times, cycles)
        self.shown = -1
        self.stats = dict(n=0, t0=0.0, times=deque(maxlen=60), stamps=deque(maxlen=60), error="")
        self.verifier = None
        self.disp_stamps = deque(maxlen=60)
        self.photo_in = self.photo_out = None
        root.title("PATRM video over Ethernet")
        self._build(a)
        self._tick()

    # ---------------------------------------------------------------- layout
    def _build(self, a):
        top = ttk.Frame(self.root, padding=6)
        top.pack(fill="x")
        self.v_folder = tk.StringVar(value=a.frames)
        self.v_size = tk.StringVar(value=f"{a.size[0]}x{a.size[1]}")
        self.v_tf = tk.StringVar(value=a.transform)
        self.v_engine = tk.StringVar(value="fpga")
        self.v_loop = tk.BooleanVar(value=True)
        self.v_limit = tk.BooleanVar(value=False)
        ttk.Label(top, text="Frames").grid(row=0, column=0, sticky="w")
        ttk.Entry(top, textvariable=self.v_folder, width=52).grid(row=0, column=1, columnspan=4, sticky="we")
        ttk.Button(top, text="Browse", command=self.browse).grid(row=0, column=5, padx=4)
        ttk.Label(top, text="Size").grid(row=1, column=0, sticky="w")
        ttk.Entry(top, textvariable=self.v_size, width=10).grid(row=1, column=1, sticky="w")
        ttk.Label(top, text="Transform").grid(row=1, column=2, sticky="e")
        ttk.Combobox(top, textvariable=self.v_tf, values=TRANSFORMS, width=14).grid(row=1, column=3, sticky="w")
        eng = ttk.Frame(top)
        eng.grid(row=1, column=4, sticky="w", padx=8)
        ttk.Label(eng, text="Engine").pack(side="left")
        ttk.Radiobutton(eng, text="FPGA", value="fpga", variable=self.v_engine).pack(side="left")
        ttk.Radiobutton(eng, text="ARM", value="arm", variable=self.v_engine).pack(side="left")
        btn = ttk.Frame(top)
        btn.grid(row=2, column=0, columnspan=6, sticky="w", pady=4)
        ttk.Button(btn, text="Load board", command=self.load_board).pack(side="left")
        ttk.Button(btn, text="Load frames", command=self.load_frames).pack(side="left", padx=4)
        self.b_play = ttk.Button(btn, text="Play", command=self.play)
        self.b_play.pack(side="left", padx=4)
        ttk.Button(btn, text="Stop", command=self.stop).pack(side="left")
        ttk.Checkbutton(btn, text="Loop", variable=self.v_loop).pack(side="left", padx=8)
        ttk.Checkbutton(btn, text="Limit 60 fps", variable=self.v_limit).pack(side="left")

        views = ttk.Frame(self.root, padding=6)
        views.pack()
        self.l_in_title = ttk.Label(views, text="Input (PC -> board)", font=("Segoe UI", 10, "bold"))
        self.l_in_title.grid(row=0, column=0)
        self.l_out_title = ttk.Label(views, text="Output (FPGA engine)", font=("Segoe UI", 10, "bold"))
        self.l_out_title.grid(row=0, column=1)
        # each view: at most VIEW_W, and both must fit next to each other on this screen
        self.view_w = max(240, min(VIEW_W, (self.root.winfo_screenwidth() - 80) // 2))
        self.c_in = tk.Label(views, bg="#202020")
        self.c_in.grid(row=1, column=0, padx=4)
        self.c_out = tk.Label(views, bg="#202020")
        self.c_out.grid(row=1, column=1, padx=4)

        info = ttk.Frame(self.root, padding=6)
        info.pack(fill="x")
        self.l_fps = ttk.Label(info, text="stream -- fps", font=("Segoe UI", 16, "bold"))
        self.l_fps.grid(row=0, column=0, sticky="w")
        self.l_disp = ttk.Label(info, text="display -- fps")
        self.l_disp.grid(row=0, column=1, sticky="w", padx=16)
        self.l_check = ttk.Label(info, text="model check: --", font=("Segoe UI", 12, "bold"))
        self.l_check.grid(row=0, column=2, sticky="w", padx=16)
        self.l_times = ttk.Label(info, text="", font=("Consolas", 10))
        self.l_times.grid(row=1, column=0, columnspan=3, sticky="w")
        self.l_status = ttk.Label(self.root, text="Load frames, then Play. Load board first if the board is not "
                                                  "running patrm_eth.elf.", padding=6, foreground="#333")
        self.l_status.pack(fill="x")

    def status(self, text, color="#333"):
        self.root.after(0, lambda: self.l_status.config(text=text, foreground=color))

    # ---------------------------------------------------------------- actions
    def browse(self):
        d = filedialog.askdirectory(initialdir=self.v_folder.get())
        if d:
            self.v_folder.set(d)

    def load_board(self):
        def work():
            try:
                self.status("Programming the FPGA and starting patrm_eth.elf ...")
                EL.load_board()
                self.status("Waiting for the board to boot (about 27 s) ...")
                s = EL.wait_ready()
                self.status(f"Board ready after {s:.0f} s.", "#060")
            except Exception as e:             # shown to the user, never silent
                self.status(f"Load board failed: {e}", "#B00")
        threading.Thread(target=work, daemon=True).start()

    def load_frames(self):
        if self.running:
            return

        def work():
            try:
                W, H = VS.parse_size(self.v_size.get())
                frames, files = VS.load_frames(self.v_folder.get(), W, H,
                                               progress=lambda i, n: self.status(f"Preparing frames {i} / {n} ..."))
                bs = VS.transform_list(self.v_tf.get(), len(frames), W, H)
                self.frames, self.files, self.bs, self.size = frames, files, bs, (W, H)
                self.status(f"{len(frames)} frames ready at {W}x{H}, transform {self.v_tf.get()}.", "#060")
            except Exception as e:
                self.status(f"Load frames failed: {e}", "#B00")
        threading.Thread(target=work, daemon=True).start()

    def play(self):
        if self.running:
            return
        if not self.frames:
            self.status("Load frames first.", "#B00")
            return
        try:                                     # transform may have been changed after loading
            self.bs = VS.transform_list(self.v_tf.get(), len(self.frames), *self.size)
        except Exception as e:
            self.status(f"Transform: {e}", "#B00")
            return
        engine = self.v_engine.get()
        self.l_out_title.config(text="Output (FPGA engine)" if engine == "fpga" else "Output (ARM software baseline)")
        self.running = True
        self.stats = dict(n=0, t0=time.perf_counter(), times=deque(maxlen=60), stamps=deque(maxlen=60), error="")
        self.verifier = VS.Verifier()
        self.worker = threading.Thread(target=self._stream, args=(engine,), daemon=True)
        self.worker.start()
        self.status(f"Playing through the {engine.upper()} ...")

    def stop(self):
        if not self.running:
            return
        self.running = False
        self.status("Stopping; finishing the model check ...")

    # ---------------------------------------------------------------- streaming thread
    def _stream(self, engine):
        W, H = self.size
        try:
            st = VS.Streamer(W, H, engine)
        except Exception as e:
            self.stats["error"] = f"cannot connect to the board: {e}"
            self.running = False
            self._finish(engine)
            return
        k = 0
        next_t = time.perf_counter()
        try:
            while self.running:
                i = k % len(self.frames)
                if k and i == 0 and not self.v_loop.get():
                    break
                src, b = self.frames[i], self.bs[i]
                out, r, t = st.frame(src, b)
                self.verifier.submit(k, src, W, H, b, out.tobytes())
                now = time.perf_counter()
                with self.lock:
                    self.latest = (k, src, out, t, r["cycles"])
                    self.stats["n"] = k + 1
                    self.stats["times"].append(t)
                    self.stats["stamps"].append(now)
                k += 1
                if self.v_limit.get():
                    next_t = max(next_t + 1 / 60, now - 0.1)
                    delay = next_t - time.perf_counter()
                    if delay > 0:
                        time.sleep(delay)
        except Exception as e:
            self.stats["error"] = str(e)
        finally:
            st.close()
            self.running = False
            self._finish(engine)

    def _finish(self, engine):
        n = self.stats["n"]
        elapsed = time.perf_counter() - self.stats["t0"]
        checked, nbad = self.verifier.finish() if self.verifier else (0, 0)
        bad = self.verifier.bad[:5] if self.verifier else []
        if self.verifier and checked != n:
            self.stats["error"] = (self.stats["error"] + "; " if self.stats["error"] else "") + \
                f"only {checked} of {n} frames were checked"
        W, H = self.size
        fps = n / elapsed if elapsed > 0 and n else 0.0
        text = (f"{n} frames {W}x{H}, transform {self.v_tf.get()}, engine {engine}: {fps:.1f} fps average; "
                f"model check {checked - nbad} of {checked} bit-exact" + (f", differing {bad}" if nbad else "")
                + (f"; error: {self.stats['error']}" if self.stats["error"] else ""))
        VS.OUT_DIR.mkdir(parents=True, exist_ok=True)
        stamp = dt.datetime.now().strftime("%Y-%m-%d_%H%M%S")
        (VS.OUT_DIR / f"video_gui_{stamp}.txt").write_text(text + "\n", encoding="utf-8")
        self.status(text, "#060" if not nbad and not self.stats["error"] else "#B00")

    # ---------------------------------------------------------------- display loop (GUI thread)
    def _tick(self):
        with self.lock:
            latest = self.latest
            times = list(self.stats["times"])
            stamps = list(self.stats["stamps"])
            n = self.stats["n"]
        if latest and latest[0] != self.shown:
            k, src, out, t, cycles = latest
            self.shown = k
            self._show(src, out)
            now = time.perf_counter()
            self.disp_stamps.append(now)
            if len(stamps) >= 2:
                self.l_fps.config(text=f"stream {(len(stamps) - 1) / (stamps[-1] - stamps[0]):5.1f} fps")
            med = {key: VS.median([x[key] for x in times]) for key in t}
            if len(self.disp_stamps) >= 2:
                d = self.disp_stamps
                eng_fps = 1000.0 / med["engine"] if med["engine"] > 0 else 0.0
                self.l_disp.config(text=f"warp alone {eng_fps:6.1f} fps   |   display {(len(d) - 1) / (d[-1] - d[0]):5.1f} fps")
            self.l_times.config(text=(
                f"frame {k:5d} ({n} sent)  CYCLES {cycles:9d}   median of last {len(times)} frames: "
                f"upload {med['upload']:5.2f} | board receive {med['board_rx']:5.2f} | board job {med['board_job']:5.2f}"
                f" (engine {med['engine']:5.2f}) | download {med['download']:5.2f} | round trip {med['round_trip']:5.2f}"
                f" ms"))
        if self.verifier and self.running:
            checked, nbad = self.verifier.poll()
            color = "#B00" if nbad else "#060"
            self.l_check.config(text=f"model check: {checked - nbad} of {checked} bit-exact", foreground=color)
        self.root.after(10, self._tick)

    def _show(self, src, out):
        H, W = src.shape
        s = min(1.0, self.view_w / W)
        size = (max(1, int(W * s)), max(1, int(H * s)))
        a = Image.fromarray(src).resize(size, Image.BILINEAR)
        b = Image.fromarray(out).resize(size, Image.BILINEAR)
        self.photo_in = ImageTk.PhotoImage(a)
        self.photo_out = ImageTk.PhotoImage(b)
        self.c_in.config(image=self.photo_in, width=size[0], height=size[1])
        self.c_out.config(image=self.photo_out, width=size[0], height=size[1])


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--frames", default=str(VS.DEFAULT_FRAMES))
    ap.add_argument("--size", type=VS.parse_size, default=(800, 480))
    ap.add_argument("--transform", default="spin")
    ap.add_argument("--screenshot", default="", help="(testing) load frames, play 3 s, save a screenshot, quit")
    a = ap.parse_args(argv)
    try:                                         # sharp text and true pixel sizes on scaled Windows displays
        import ctypes
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except (AttributeError, OSError):
        pass
    root = tk.Tk()
    gui = VideoGui(root, a)
    if a.screenshot:
        def shot():
            from PIL import ImageGrab
            root.update()
            x, y = root.winfo_rootx(), root.winfo_rooty()
            ImageGrab.grab((x, y, x + root.winfo_width(), y + root.winfo_height())).save(a.screenshot)
            gui.stop()
            root.after(4000, root.destroy)
        gui.load_frames()
        root.after(4000, gui.play)
        root.after(9000, shot)
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
