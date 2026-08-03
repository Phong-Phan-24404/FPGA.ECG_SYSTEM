# Standalone synthesis timing contract for the packaged AXI IP.
# The system-level design supplies the physical clock and I/O constraints.
# The bundled testbench drives s_axi_aclk with a 10 ns period (100 MHz).
create_clock -name s_axi_aclk -period 10.000 [get_ports s_axi_aclk]
