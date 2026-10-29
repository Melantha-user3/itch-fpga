// itch_decoder: turns one ITCH 5.0 message into named fields (one cycle).
//
// Every ITCH 5.0 message starts with the same 11 bytes:
//   0 type, 1-2 stock locate, 3-4 tracking number, 5-10 timestamp (ns since midnight)
// Order-book messages decoded here (offsets from byte 0, big-endian):
//   'A' Add Order (36)        11 order ref(8), 19 side(1), 20 shares(4), 24 stock(8), 32 price(4)
//   'F' Add Order w/ MPID (40) same as 'A' + 36 attribution(4)
//   'E' Order Executed (31)   11 order ref(8), 19 executed shares(4), 23 match number(8)
//   'C' Executed w/ Price (36) like 'E' + 31 printable(1), 32 execution price(4)
//   'X' Order Cancel (23)     11 order ref(8), 19 cancelled shares(4)
//   'D' Order Delete (19)     11 order ref(8)
//   'U' Order Replace (35)    11 original ref(8), 19 new ref(8), 27 shares(4), 31 price(4)
// Other message types only get the common fields; `known` is 0 for them.
// Fields that a message type does not have are output as 0.
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

    always_ff @(posedge clk) begin
        if (rst) begin
            m_valid <= 1'b0;
        end else begin
            m_valid <= s_valid;
        end

        if (s_valid) begin
            m_known         <= known;
            m_seq           <= s_seq;
            m_type          <= t;
            m_locate        <= be16(s_msg, 1);
            m_tracking      <= be16(s_msg, 3);
            m_timestamp     <= {be16(s_msg, 5), be32(s_msg, 7)};
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
                m_order_ref <= be64(s_msg, 11);
                case (t)
                    "A", "F": begin
                        m_side   <= b(s_msg, 19);
                        m_shares <= be32(s_msg, 20);
                        m_stock  <= be64(s_msg, 24);
                        m_price  <= be32(s_msg, 32);
                        if (t == "F") m_attribution <= be32(s_msg, 36);
                    end
                    "E", "C": begin
                        m_shares <= be32(s_msg, 19);
                        m_match  <= be64(s_msg, 23);
                        if (t == "C") begin
                            m_printable <= b(s_msg, 31);
                            m_price     <= be32(s_msg, 32);
                        end
                    end
                    "X": m_shares <= be32(s_msg, 19);
                    "U": begin
                        m_new_order_ref <= be64(s_msg, 19);
                        m_shares        <= be32(s_msg, 27);
                        m_price         <= be32(s_msg, 31);
                    end
                    default: ;
                endcase
            end
        end
    end
endmodule
