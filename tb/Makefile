# Run all tests:            make
# One test:                 make COCOTB_TEST_FILTER=test_single_add_order
# Waveform (sim_build/*.fst): make WAVES=1
# Test another version:     make DECODER=path/to/itch_decoder.sv
#                           (also RX=... and FRAMER=...)
SIM ?= icarus
TOPLEVEL_LANG = verilog

RTL := $(abspath ../rtl)
RX      ?= $(RTL)/eth_ip_udp_rx.sv
FRAMER  ?= $(RTL)/moldudp64_framer.sv
DECODER ?= $(RTL)/itch_decoder.sv
VERILOG_SOURCES = $(abspath $(RX)) $(abspath $(FRAMER)) $(abspath $(DECODER)) \
                  $(RTL)/itch_parser_top.sv
COMPILE_ARGS += -g2012

# Rebuild when the file list changes (e.g. switching DECODER=...), not only
# when a file is edited
SRC_STAMP := sim_build/.sources
$(shell mkdir -p sim_build; echo '$(VERILOG_SOURCES)' | cmp -s - $(SRC_STAMP) || echo '$(VERILOG_SOURCES)' > $(SRC_STAMP))
CUSTOM_COMPILE_DEPS += $(SRC_STAMP)

COCOTB_TOPLEVEL = itch_parser_top
COCOTB_TEST_MODULES = test_parser
export PYTHONPATH := $(abspath ../model):$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim
