// syn_wrapper: puts itch_parser_top on real FPGA pins for timing/area numbers.
//
// The parser has ~600 output bits, more than the chip has pins, so all
// output fields are XOR-folded into 16 registered pins. The fold keeps every
// output bit "used", so the synthesizer cannot delete any of the parser.
// Inputs are registered once so the timing measures the parser, not the pads.
module syn_wrapper (
    input  logic        clk,
    input  logic        rst,
    input  logic [63:0] s_axis_tdata,
    input  logic [7:0]  s_axis_tkeep,
    input  logic        s_axis_tvalid,
    input  logic        s_axis_tlast,
    output logic        s_axis_tready,
    output logic [15:0] fold
);
    logic [63:0] d_q;
    logic [7:0]  k_q;
    logic        v_q, l_q, r_q, ready;

    always_ff @(posedge clk) begin
        r_q <= rst;
        if (ready || !v_q) begin
            d_q <= s_axis_tdata;
            k_q <= s_axis_tkeep;
            v_q <= s_axis_tvalid;
            l_q <= s_axis_tlast;
        end
    end
    assign s_axis_tready = ready || !v_q;

    logic m_valid, m_known, st_drop, st_done, st_err;
    logic [63:0] m_seq, m_order_ref, m_new_order_ref, m_stock, m_match;
    logic [7:0]  m_type, m_side, m_printable;
    logic [15:0] m_locate, m_tracking;
    logic [47:0] m_timestamp;
    logic [31:0] m_shares, m_price, m_attribution;

    itch_parser_top u_dut (
        .clk, .rst(r_q), .cfg_udp_port(16'd26477),
        .s_axis_tdata(d_q), .s_axis_tkeep(k_q), .s_axis_tvalid(v_q),
        .s_axis_tlast(l_q), .s_axis_tready(ready),
        .m_valid, .m_known, .m_seq, .m_type, .m_locate, .m_tracking, .m_timestamp,
        .m_order_ref, .m_new_order_ref, .m_side, .m_shares, .m_stock, .m_price,
        .m_match, .m_attribution, .m_printable,
        .stat_pkt_drop(st_drop), .stat_pkt_done(st_done), .stat_pkt_err(st_err)
    );

    wire [575:0] all_out = {m_seq, m_order_ref, m_new_order_ref, m_stock, m_match,
                            m_timestamp, m_shares, m_price, m_attribution,
                            m_locate, m_tracking, m_type, m_side, m_printable,
                            m_valid, m_known, st_drop, st_done, st_err, 3'b000};
    always_ff @(posedge clk) begin
        for (int i = 0; i < 16; i++) begin
            fold[i] <= ^all_out[i*36 +: 36];
        end
    end
endmodule
