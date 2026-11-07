"""Test window for the reference model (Tkinter, numpy, Pillow).

    python -m model.warp_gui

Open a photo (or an existing .raw), pick a size, a transform and grayscale/Bayer, press Run: input and
output are shown side by side with the b integers, the T_p values (Bayer) and the run time.
All image work goes through the same functions as try_warp.py / raw2png.py (load_photo, run_warp,
array_to_image, read_raw); there is no warp code here.

Automation (for checks and screenshots):
    python -m model.warp_gui --photo data/photos/x.jpg --size 640x480 --preset rot15 [--bayer] --run
                             [--screenshot results/gui.png] [--quit]
"""

import argparse
import os
import queue
import sys
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, simpledialog, ttk

import numpy as np

from model import gen_transforms
from model.raw2png import array_to_image, read_raw
from model.try_warp import forward_params, load_photo, run_warp

SIM_SIZES = ["64x64", "128x96", "256x192"]
BOARD_SIZES = ["480x272", "640x480", "800x480", "1920x1080", "2448x2048"]
GRAY_ONLY = ["2448x2095"]
SIZES = BOARD_SIZES + GRAY_ONLY + SIM_SIZES
MIRRORS = ["none", "columns", "rows"]


def parse_size(s):
    W, H = (int(x) for x in s.lower().split("x"))
    return W, H


class WarpGui:
    def __init__(self, root):
        self.root = root
        root.title("Bayer-PATRM reference model: test window")
        root.geometry("1280x820")
        root.minsize(900, 600)
        self.photo_path = None
        self.raw_src = None          # (array, W, H, bayer) when a raw file is loaded
        self.result = None           # dict from the last run
        self.views = (None, None)    # PIL images shown (input, output)
        self.tk_imgs = []
        self.q = queue.Queue()
        self.busy = False
        self.on_done = None
        self.presets = {t["name"]: t["forward"] for t in gen_transforms.load()}
        self._build()
        root.after(50, self._poll)

    # ------------------------------------------------------------------ layout
    def _build(self):
        r = self.root
        top = ttk.Frame(r, padding=6)
        top.pack(side=tk.TOP, fill=tk.X)
        ttk.Button(top, text="Open photo", command=self.open_photo).pack(side=tk.LEFT)
        ttk.Button(top, text="Open raw", command=self.open_raw).pack(side=tk.LEFT, padx=(4, 12))
        self.src_label = ttk.Label(top, text="no input", width=40)
        self.src_label.pack(side=tk.LEFT)
        sf = ttk.Frame(r, padding=(6, 0, 6, 6))
        sf.pack(side=tk.TOP, fill=tk.X)
        ttk.Label(sf, text="Size (W x H):").pack(side=tk.LEFT, padx=(0, 2))
        self.size = tk.StringVar(value="640x480")
        self.size_box = ttk.Combobox(sf, textvariable=self.size, values=SIZES, width=11, state="readonly")
        self.size_box.pack(side=tk.LEFT)
        self.mode = tk.StringVar(value="gray")
        self.rb_gray = ttk.Radiobutton(sf, text="Grayscale", variable=self.mode, value="gray")
        self.rb_bayer = ttk.Radiobutton(sf, text="Bayer RGGB", variable=self.mode, value="bayer")
        self.rb_gray.pack(side=tk.LEFT, padx=(12, 0))
        self.rb_bayer.pack(side=tk.LEFT)
        self.show_mosaic = tk.BooleanVar(value=False)
        ttk.Checkbutton(sf, text="show raw mosaic (Bayer)", variable=self.show_mosaic,
                        command=self.refresh_views).pack(side=tk.LEFT, padx=(8, 0))

        tf = ttk.Frame(r, padding=(6, 0, 6, 6))
        tf.pack(side=tk.TOP, fill=tk.X)
        ttk.Label(tf, text="Preset:").pack(side=tk.LEFT)
        self.preset = tk.StringVar(value="")
        pb = ttk.Combobox(tf, textvariable=self.preset, values=list(self.presets), width=12, state="readonly")
        pb.pack(side=tk.LEFT)
        pb.bind("<<ComboboxSelected>>", lambda e: self.apply_preset(self.preset.get()))
        self.rot = tk.StringVar(value="15")
        self.scale = tk.StringVar(value="1")
        self.shift_r = tk.StringVar(value="0")
        self.shift_c = tk.StringVar(value="0")
        for label, var, w in (("Rotation (deg, + = CCW):", self.rot, 7), ("Scale (S or SX SY):", self.scale, 9),
                              ("Shift rows:", self.shift_r, 6), ("cols:", self.shift_c, 6)):
            ttk.Label(tf, text=label).pack(side=tk.LEFT, padx=(12, 2))
            ttk.Entry(tf, textvariable=var, width=w).pack(side=tk.LEFT)
        ttk.Label(tf, text="Mirror:").pack(side=tk.LEFT, padx=(12, 2))
        self.mirror = tk.StringVar(value="none")
        ttk.Combobox(tf, textvariable=self.mirror, values=MIRRORS, width=8, state="readonly").pack(side=tk.LEFT)

        bf = ttk.Frame(r, padding=(6, 0, 6, 6))
        bf.pack(side=tk.TOP, fill=tk.X)
        self.run_btn = ttk.Button(bf, text="Run", command=self.run)
        self.run_btn.pack(side=tk.LEFT)
        ttk.Button(bf, text="Save output", command=self.save).pack(side=tk.LEFT, padx=4)
        fpga = ttk.Button(bf, text="Run on FPGA  (reserved for step 8.3)", state=tk.DISABLED)
        fpga.pack(side=tk.LEFT, padx=(24, 0))
        self.status = tk.Label(bf, text="", anchor="w", fg="black")
        self.status.pack(side=tk.LEFT, padx=12, fill=tk.X, expand=True)

        bottom = ttk.Frame(r, padding=6)
        bottom.pack(side=tk.BOTTOM, fill=tk.X)
        self.info = tk.Label(bottom, text="", anchor="w", justify=tk.LEFT, font=("Consolas", 10))
        self.info.pack(side=tk.LEFT, fill=tk.X)

        self.panel = tk.Frame(r, bg="#808080")
        self.panel.pack(side=tk.TOP, fill=tk.BOTH, expand=True, padx=6)
        self.cap = []
        self.lbl = []
        for k, title in enumerate(("input", "output (reference model)")):
            f = tk.Frame(self.panel, bg="#808080")
            f.place(relx=k / 2, rely=0, relwidth=0.5, relheight=1)
            c = tk.Label(f, text=title, bg="#808080", fg="white")
            c.pack(side=tk.TOP)
            l = tk.Label(f, bg="#808080")
            l.pack(side=tk.TOP, fill=tk.BOTH, expand=True)
            self.cap.append(c)
            self.lbl.append(l)
        self._resize_job = None
        self.panel.bind("<Configure>", self._on_resize)

    # ------------------------------------------------------------------ inputs
    def open_photo(self, path=None):
        path = path or filedialog.askopenfilename(
            title="Open photo", filetypes=[("Images", "*.jpg *.jpeg *.png"), ("All files", "*.*")])
        if not path:
            return
        self.photo_path, self.raw_src = path, None
        self.size_box.configure(state="readonly")
        self.rb_gray.configure(state=tk.NORMAL)
        self.rb_bayer.configure(state=tk.NORMAL)
        self.src_label.configure(text=f"photo: {os.path.basename(path)}")
        self.set_status("photo loaded; press Run")

    def open_raw(self):
        path = filedialog.askopenfilename(title="Open raw", filetypes=[("Raw", "*.raw"), ("All files", "*.*")])
        if not path:
            return
        s = simpledialog.askstring("Raw size", "Size W x H (e.g. 640x480):", parent=self.root)
        if not s:
            return
        try:
            W, H = parse_size(s)
        except ValueError:
            self.set_error(f"size must be W x H, got {s!r}")
            return
        bayer = messagebox.askyesno("Raw format", "Is this a Bayer RGGB mosaic?\n(No = grayscale)", parent=self.root)
        try:
            arr = read_raw(path, W, H)
        except (ValueError, OSError) as e:
            self.set_error(str(e))
            return
        self.raw_src, self.photo_path = (arr, W, H, bayer), None
        self.size.set(f"{W}x{H}")
        self.size_box.configure(state=tk.DISABLED)
        self.mode.set("bayer" if bayer else "gray")
        self.rb_gray.configure(state=tk.DISABLED)
        self.rb_bayer.configure(state=tk.DISABLED)
        self.src_label.configure(text=f"raw: {os.path.basename(path)} ({W}x{H}, {'Bayer' if bayer else 'gray'})")
        self.set_status("raw loaded (size and mode fixed by the file); press Run")

    def apply_preset(self, name):
        fw = self.presets[name]
        self.rot.set(f"{fw.get('rot_deg', 0.0):g}")
        sx, sy = fw.get("sx", 1.0), fw.get("sy", 1.0)
        self.scale.set(f"{sx:g}" if sx == sy else f"{sx:g} {sy:g}")
        sh = fw.get("shift", [0.0, 0.0])
        self.shift_r.set(f"{sh[0]:g}")
        self.shift_c.set(f"{sh[1]:g}")
        self.mirror.set("columns" if fw.get("mirror_cols") else "rows" if fw.get("mirror_rows") else "none")

    # ------------------------------------------------------------------ run
    def set_status(self, text, color="black"):
        self.status.configure(text=text, fg=color)

    def set_error(self, text):
        self.set_status("error: " + text, "red")

    def run(self):
        if self.busy:
            return
        if self.photo_path is None and self.raw_src is None:
            self.set_error("open a photo or a raw file first")
            return
        try:
            W, H = parse_size(self.size.get())
            scale = tuple(float(x) for x in self.scale.get().split())
            mirror = {"none": None, "columns": "cols", "rows": "rows"}[self.mirror.get()]
            fw = forward_params(float(self.rot.get()), scale, (float(self.shift_r.get()), float(self.shift_c.get())),
                                mirror)
        except ValueError as e:
            self.set_error(f"bad transform field: {e}")
            return
        bayer = self.mode.get() == "bayer"
        mosaic = self.show_mosaic.get()
        photo, raw = self.photo_path, self.raw_src

        def work():
            try:
                t0 = time.perf_counter()
                src = raw[0] if raw is not None else load_photo(photo, W, H, bayer)
                t1 = time.perf_counter()
                out, b, T = run_warp(src, W, H, fw, bayer)
                t2 = time.perf_counter()
                views = (array_to_image(src, bayer, mosaic), array_to_image(out, bayer, mosaic))
                self.q.put(("done", dict(src=src, out=out, b=b, T=T, W=W, H=H, bayer=bayer, fw=fw,
                                         t_load=t1 - t0, t_warp=t2 - t1), views))
            except ValueError as e:          # D3 / D4 and similar
                self.q.put(("error", str(e), None))
            except Exception as e:           # keep the window alive on anything else
                self.q.put(("error", f"{type(e).__name__}: {e}", None))

        self._start(work, f"working... ({W}x{H}, {'Bayer' if bayer else 'gray'})")

    def refresh_views(self):
        if self.result is None or self.busy:
            return
        res, mosaic = self.result, self.show_mosaic.get()

        def work():
            views = (array_to_image(res["src"], res["bayer"], mosaic), array_to_image(res["out"], res["bayer"], mosaic))
            self.q.put(("views", None, views))

        self._start(work, "working... (redrawing)")

    def _start(self, fn, msg):
        self.busy = True
        self.run_btn.configure(state=tk.DISABLED)
        self.set_status(msg, "blue")
        threading.Thread(target=fn, daemon=True).start()

    def _poll(self):
        try:
            while True:
                kind, payload, views = self.q.get_nowait()
                self.busy = False
                self.run_btn.configure(state=tk.NORMAL)
                if kind == "error":
                    self.set_error(payload)
                elif kind == "done":
                    self.result = payload
                    self.show_info()
                    self.set_status(f"done: model {payload['t_warp'] * 1000:.0f} ms", "dark green")
                else:
                    self.set_status("done", "dark green")
                if views is not None:
                    self.views = views
                    self.draw()
                if self.on_done:
                    cb, self.on_done = self.on_done, None
                    self.root.after(300, cb)
        except queue.Empty:
            pass
        self.root.after(50, self._poll)

    # ------------------------------------------------------------------ display
    def show_info(self):
        r = self.result
        lines = [f"b = {r['b']}  (b11 b12 b13 b21 b22 b23, Q15.16 inverse map, {r['W']}x{r['H']})"]
        if r["T"]:
            lines.append("T_p (D2):  " + "   ".join(f"{p} {r['T'][p]}" for p in ("R", "Gr", "Gb", "B")))
        lines.append(f"run time: model {r['t_warp'] * 1000:.0f} ms, input conversion {r['t_load'] * 1000:.0f} ms "
                     f"({'Bayer warp_bayer' if r['bayer'] else 'gray warp_gray'})")
        self.info.configure(text="\n".join(lines))

    def _on_resize(self, _e):
        if self._resize_job:
            self.root.after_cancel(self._resize_job)
        self._resize_job = self.root.after(120, self.draw)

    def draw(self):
        from PIL import ImageTk
        if self.views[0] is None:
            return
        self.tk_imgs = []
        for k, im in enumerate(self.views):
            w = max(50, self.lbl[k].winfo_width() - 8)
            h = max(50, self.lbl[k].winfo_height() - 8)
            s = min(w / im.width, h / im.height)
            size = (max(1, int(im.width * s)), max(1, int(im.height * s)))
            from PIL import Image
            shown = im.resize(size, Image.NEAREST if s >= 1 else Image.BILINEAR)
            ti = ImageTk.PhotoImage(shown)
            self.tk_imgs.append(ti)
            self.lbl[k].configure(image=ti)
            self.cap[k].configure(text=f"{('input', 'output (reference model)')[k]}  -  "
                                       f"{im.width}x{im.height}, shown at {100 * s:.0f}%")

    # ------------------------------------------------------------------ save
    def save(self):
        if self.result is None:
            self.set_error("nothing to save: press Run first")
            return
        path = filedialog.asksaveasfilename(title="Save output (writes .png and .raw)", defaultextension=".png",
                                            filetypes=[("PNG", "*.png")], initialfile="output.png")
        if not path:
            return
        self.save_to(path)

    def save_to(self, path):
        base = os.path.splitext(path)[0]
        self.views[1].save(base + ".png")
        np.ascontiguousarray(self.result["out"], dtype=np.uint8).tofile(base + ".raw")
        r = self.result
        self.set_status(f"saved {base}.png and {base}.raw ({r['W']}x{r['H']}, "
                        f"{'RGGB' if r['bayer'] else 'GRAY8'})", "dark green")

    def screenshot(self, path):
        from PIL import ImageGrab
        self.root.update()
        x, y = self.root.winfo_rootx(), self.root.winfo_rooty()
        w, h = self.root.winfo_width(), self.root.winfo_height()
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        ImageGrab.grab(bbox=(x, y, x + w, y + h)).save(path)


def main(argv=None):
    p = argparse.ArgumentParser(prog="python -m model.warp_gui", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--photo")
    p.add_argument("--size")
    p.add_argument("--preset")
    p.add_argument("--bayer", action="store_true")
    p.add_argument("--run", action="store_true", help="press Run once the window is up")
    p.add_argument("--screenshot", help="save a screenshot of the window after the run")
    p.add_argument("--quit", action="store_true", help="close after the run (and screenshot)")
    a = p.parse_args(argv)
    try:                                     # crisp text on Windows high-DPI screens
        import ctypes
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except Exception:
        pass
    root = tk.Tk()
    app = WarpGui(root)
    if a.photo:
        app.open_photo(a.photo)
    if a.size:
        app.size.set(a.size)
    if a.preset:
        app.preset.set(a.preset)
        app.apply_preset(a.preset)
    if a.bayer:
        app.mode.set("bayer")

    def after_run():
        if a.screenshot:
            app.screenshot(a.screenshot)
            print(f"warp_gui: screenshot -> {a.screenshot}")
        print(f"warp_gui: status = {app.status.cget('text')!r}")
        if app.result:
            print(f"warp_gui: b = {app.result['b']}")
        if a.quit:
            root.destroy()

    if a.run:
        app.on_done = after_run
        root.after(500, app.run)
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
