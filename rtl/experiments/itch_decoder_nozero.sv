// EXPERIMENT (not used by default): itch_decoder without zeroing.
// Same ports and latency as rtl/itch_decoder.sv. Every field is loaded from
// its fixed offset for every message, so fields a message type does not have
// hold leftover bytes instead of 0; a consumer must look at m_known and
// m_type before using a field. Only shares and price need a type mux, and
// `known` drives one register instead of the clear of ~370.
// Run the tests with DONT_CARE=1, which ignores the fields a type lacks:
//   cd tb  && make DECODER=../rtl/experiments/itch_decoder_nozero.sv DONT_CARE=1
//   cd syn && ./seeds.sh DECODER=../rtl/experiments/itch_decoder_nozero.sv
// Result (ECP5-25F, speed 6, seeds 1-3): 95.4 / 98.8 / 95.8 MHz. No gain on
// its own: the next paths (framer length loop, message shifter) are ~10 ns too.
// Everything else is as in rtl/itch_decoder.sv; see the comments there.
module itch_decoder #(
    parameter int MAX_MSG = 50
) (
    input  logic                 clk,
    input  logic                 rst,

    input  logic                 s_valid,
    input  logic [63:0]          s_seq,
    input  logic [5:0]           s_len,
    input  logic [8*MAX_MSG-1:0] s_msg,

    output logic        m_valid,
    output logic        m_known,     // supported type and correct length
    output logic [63:0] m_seq,
    output logic [7:0]  m_type,
    output logic [15:0] m_locate,
    output logic [15:0] m_tracking,
    output logic [47:0] m_timestamp,
    output logic [63:0] m_order_ref,
    output logic [63:0] m_new_order_ref, // 'U' only
    output logic [7:0]  m_side,          // 'B' or 'S'
    output logic [31:0] m_shares,        // A/F/U shares, E/C executed, X cancelled
    output logic [63:0] m_stock,         // 8 ASCII chars, first char in [63:56]
    output logic [31:0] m_price,         // A/F/U price, C execution price (4 implied decimals)
    output logic [63:0] m_match,         // E/C match number
    output logic [31:0] m_attribution,   // F only
    output logic [7:0]  m_printable      // C only
);
    // Field helpers. The message is passed in as an argument because Yosys
    // only accepts functions that read their own inputs.
    typedef logic [8*MAX_MSG-1:0] msg_t;
    function automatic [7:0] b(input msg_t m, input integer off);
        b = m[8*off +: 8];
    endfunction
    function automatic [15:0] be16(input msg_t m, input integer off);
        be16 = {m[8*off +: 8], m[8*(off+1) +: 8]};
    endfunction
    function automatic [31:0] be32(input msg_t m, input integer off);
        be32 = {be16(m, off), be16(m, off + 2)};
    endfunction
    function automatic [63:0] be64(input msg_t m, input integer off);
        be64 = {be32(m, off), be32(m, off + 4)};
    endfunction

    logic [7:0] t;
    logic [5:0] exp_len;
    assign t = s_msg[7:0];   // byte 0 = message type
    always_comb begin
        case (t)
            "A": exp_len = 6'd36;
            "F": exp_len = 6'd40;
            "E": exp_len = 6'd31;
            "C": exp_len = 6'd36;
            "X": exp_len = 6'd23;
            "D": exp_len = 6'd19;
            "U": exp_len = 6'd35;
            default: exp_len = 6'd0;
        endcase
    end
    wire known = (exp_len != 6'd0) && (s_len == exp_len);

    logic [31:0] shares_n, price_n;
    always_comb begin
        if (t == "U")                 shares_n = be32(s_msg, 27);
        else if (t == "A" || t == "F") shares_n = be32(s_msg, 20);
        else                          shares_n = be32(s_msg, 19);
        price_n = (t == "U") ? be32(s_msg, 31) : be32(s_msg, 32);
    end
    always_ff @(posedge clk) begin
        if (rst) m_valid <= 1'b0;
        else     m_valid <= s_valid;
        if (s_valid) begin
            m_known         <= known;
            m_seq           <= s_seq;
            m_type          <= t;
            m_locate        <= be16(s_msg, 1);
            m_tracking      <= be16(s_msg, 3);
            m_timestamp     <= {be16(s_msg, 5), be32(s_msg, 7)};
            m_order_ref     <= be64(s_msg, 11);
            m_new_order_ref <= be64(s_msg, 19);
            m_side          <= b(s_msg, 19);
            m_shares        <= shares_n;
            m_stock         <= be64(s_msg, 24);
            m_price         <= price_n;
            m_match         <= be64(s_msg, 23);
            m_attribution   <= be32(s_msg, 36);
            m_printable     <= b(s_msg, 31);
        end
    end
endmodule
