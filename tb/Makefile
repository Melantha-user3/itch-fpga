# Run all tests:            make
# One test:                 make COCOTB_TEST_FILTER=test_single_add_order
# Waveform (sim_build/*.fst): make WAVES=1
SIM ?= icarus
TOPLEVEL_LANG = verilog

RTL := $(abspath ../rtl)
VERILOG_SOURCES = $(RTL)/eth_ip_udp_rx.sv $(RTL)/moldudp64_framer.sv \
                  $(RTL)/itch_decoder.sv $(RTL)/itch_parser_top.sv
COMPILE_ARGS += -g2012

COCOTB_TOPLEVEL = itch_parser_top
COCOTB_TEST_MODULES = test_parser
export PYTHONPATH := $(abspath ../model):$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim
