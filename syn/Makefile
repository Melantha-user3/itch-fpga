# Synthesis + place & route for Lattice ECP5 (LFE5U-25F, CABGA256), open-source flow.
#   make            -> report.txt (Fmax and resource use)
DEVICE  ?= --25k
PACKAGE ?= CABGA256
FREQ    ?= 250
SEED    ?= 1
# Synthesize another version: make clean && make DECODER=path/to/itch_decoder.sv
RX      ?= ../rtl/eth_ip_udp_rx.sv
FRAMER  ?= ../rtl/moldudp64_framer.sv
DECODER ?= ../rtl/itch_decoder.sv
RTL := $(RX) $(FRAMER) $(DECODER) ../rtl/itch_parser_top.sv syn_wrapper.sv

all: report.txt

syn.json: $(RTL)
	yosys -q -l yosys.log -p "read_verilog -sv $(RTL); synth_ecp5 -top syn_wrapper -json $@"

pnr.log: syn.json
	nextpnr-ecp5 $(DEVICE) --package $(PACKAGE) --json $< --freq $(FREQ) --seed $(SEED) \
	    --lpf-allow-unconstrained --timing-allow-fail --report pnr_report.json -l $@ -q

report.txt: pnr.log
	@grep -E "Max frequency for clock|Info:\s+(TRELLIS_COMB|TRELLIS_FF|TRELLIS_IO|DP16KD|MULT18X18D|CCU2C|LUT4):|Device utilisation" -A0 pnr.log | tee $@

# Resource use per module (hierarchy kept, so totals differ slightly from report.txt)
area: $(RTL)
	yosys -q -p "read_verilog -sv $(RTL); synth_ecp5 -top syn_wrapper -noflatten; tee -q -o area.txt stat"
	@grep -E "^=== |LUT4 |CCU2C |TRELLIS_FF " area.txt

clean:
	rm -f syn.json pnr.log pnr_report.json yosys.log report.txt area.txt

.PHONY: all area clean
