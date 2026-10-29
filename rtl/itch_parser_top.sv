// itch_parser_top: Ethernet frame in (64-bit AXI-Stream), decoded ITCH messages out.
//
//   eth_ip_udp_rx  ->  moldudp64_framer  ->  itch_decoder
//   (strip headers)    (cut messages)        (pull out fields)
module itch_parser_top #(
    parameter int MAX_MSG = 50
) (
    input  logic        clk,
    input  logic        rst,
    input  logic [15:0] cfg_udp_port,

    input  logic [63:0] s_axis_tdata,
    input  logic [7:0]  s_axis_tkeep,
    input  logic        s_axis_tvalid,
    input  logic        s_axis_tlast,
    output logic        s_axis_tready,

    output logic        m_valid,
    output logic        m_known,
    output logic [63:0] m_seq,
    output logic [7:0]  m_type,
    output logic [15:0] m_locate,
    output logic [15:0] m_tracking,
    output logic [47:0] m_timestamp,
    output logic [63:0] m_order_ref,
    output logic [63:0] m_new_order_ref,
    output logic [7:0]  m_side,
    output logic [31:0] m_shares,
    output logic [63:0] m_stock,
    output logic [31:0] m_price,
    output logic [63:0] m_match,
    output logic [31:0] m_attribution,
    output logic [7:0]  m_printable,

    output logic        stat_pkt_drop,  // filtered by Ethernet/IP/UDP checks
    output logic        stat_pkt_done,
    output logic        stat_pkt_err    // bad MoldUDP64 framing (valid with stat_pkt_done)
);
    logic [63:0] p_tdata;
    logic [7:0]  p_tkeep;
    logic        p_tvalid, p_tlast, p_tready;

    eth_ip_udp_rx u_rx (
        .clk, .rst, .cfg_udp_port,
        .s_tdata(s_axis_tdata), .s_tkeep(s_axis_tkeep), .s_tvalid(s_axis_tvalid),
        .s_tlast(s_axis_tlast), .s_tready(s_axis_tready),
        .m_tdata(p_tdata), .m_tkeep(p_tkeep), .m_tvalid(p_tvalid),
        .m_tlast(p_tlast), .m_tready(p_tready),
        .pkt_drop(stat_pkt_drop)
    );

    logic                 f_valid;
    logic [63:0]          f_seq;
    logic [5:0]           f_len;
    logic [8*MAX_MSG-1:0] f_msg;

    moldudp64_framer #(.MAX_MSG(MAX_MSG)) u_framer (
        .clk, .rst,
        .s_tdata(p_tdata), .s_tkeep(p_tkeep), .s_tvalid(p_tvalid),
        .s_tlast(p_tlast), .s_tready(p_tready),
        .m_valid(f_valid), .m_seq(f_seq), .m_len(f_len), .m_msg(f_msg),
        .pkt_done(stat_pkt_done), .pkt_err(stat_pkt_err)
    );

    itch_decoder #(.MAX_MSG(MAX_MSG)) u_dec (
        .clk, .rst,
        .s_valid(f_valid), .s_seq(f_seq), .s_len(f_len), .s_msg(f_msg),
        .m_valid, .m_known, .m_seq, .m_type, .m_locate, .m_tracking, .m_timestamp,
        .m_order_ref, .m_new_order_ref, .m_side, .m_shares, .m_stock, .m_price,
        .m_match, .m_attribution, .m_printable
    );
endmodule
