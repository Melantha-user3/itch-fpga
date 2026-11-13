// EXPERIMENT (not used by default): itch_decoder with one extra register
// stage in front of the field decode, so the type/length check (`known`)
// starts from a register. Same outputs as rtl/itch_decoder.sv, one cycle
// later (latency 3-4 cycles instead of 2-3).
//   cd tb  && make DECODER=../rtl/experiments/itch_decoder_pipe.sv
//   cd syn && ./seeds.sh DECODER=../rtl/experiments/itch_decoder_pipe.sv
// Result (ECP5-25F, speed 6, seeds 1-3): 105.0 / 99.7 / 99.0 MHz. Per message
// that is slower in nanoseconds (4 x 9.5 ns > 3 x 10.3 ns), so not adopted.
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
    wire known_c = (exp_len != 6'd0) && (s_len == exp_len);
    // Extra stage: register the message, then decode it as before
    logic                 p_valid, known;
    logic [63:0]          p_seq;
    logic [8*MAX_MSG-1:0] p_msg;
    always_ff @(posedge clk) begin
        p_valid <= rst ? 1'b0 : s_valid;
        known   <= known_c;
        p_seq   <= s_seq;
        p_msg   <= s_msg;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            m_valid <= 1'b0;
        end else begin
            m_valid <= p_valid;
        end

        if (p_valid) begin
            m_known         <= known;
            m_seq           <= p_seq;
            m_type          <= p_msg[7:0];
            m_locate        <= be16(p_msg, 1);
            m_tracking      <= be16(p_msg, 3);
            m_timestamp     <= {be16(p_msg, 5), be32(p_msg, 7)};
            m_order_ref     <= '0;
            m_new_order_ref <= '0;
            m_side          <= '0;
            m_shares        <= '0;
            m_stock         <= '0;
            m_price         <= '0;
            m_match         <= '0;
            m_attribution   <= '0;
            m_printable     <= '0;
            if (known) begin
                m_order_ref <= be64(p_msg, 11);
                case (p_msg[7:0])
                    "A", "F": begin
                        m_side   <= b(p_msg, 19);
                        m_shares <= be32(p_msg, 20);
                        m_stock  <= be64(p_msg, 24);
                        m_price  <= be32(p_msg, 32);
                        if (p_msg[7:0] == "F") m_attribution <= be32(p_msg, 36);
                    end
                    "E", "C": begin
                        m_shares <= be32(p_msg, 19);
                        m_match  <= be64(p_msg, 23);
                        if (p_msg[7:0] == "C") begin
                            m_printable <= b(p_msg, 31);
                            m_price     <= be32(p_msg, 32);
                        end
                    end
                    "X": m_shares <= be32(p_msg, 19);
                    "U": begin
                        m_new_order_ref <= be64(p_msg, 19);
                        m_shares        <= be32(p_msg, 27);
                        m_price         <= be32(p_msg, 31);
                    end
                    default: ;
                endcase
            end
        end
    end
endmodule
