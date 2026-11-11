# Out-of-context clock constraint for one engine module (D8: 100 MHz on aclk = FCLK_CLK0).
# Only register-to-register paths are timed; module ports have no I/O delays in OOC runs.
create_clock -period 10.000 -name aclk [get_ports aclk]
