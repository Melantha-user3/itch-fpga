// eth_ip_udp_rx: strips Ethernet II + IPv4 + UDP headers from a 64-bit
// AXI-Stream and outputs the UDP payload, realigned so payload byte 0 sits
// in lane 0.
//
// Byte order: packet byte k of a beat is in tdata[8*k +: 8] (lane k).
// Assumptions: FCS already removed by the MAC, tkeep is all ones except on
// the last beat (where it is contiguous from lane 0), IPv4 without options.
//
// Header byte offsets (all fixed because IHL must be 5):
//   12-13 EtherType = 0x0800       -> beat 1, lanes 4-5
//   14    Version/IHL = 0x45       -> beat 1, lane 6
//   20-21 flags/frag offset, MF=0 and offset=0 -> beat 2, lanes 4-5
//   23    protocol = 17 (UDP)      -> beat 2, lane 7
//   36-37 UDP destination port     -> beat 4, lanes 4-5
//   42..  UDP payload              -> beat 5, lane 2 onward
module eth_ip_udp_rx (
    input  logic        clk,
    input  logic        rst,
    input  logic [15:0] cfg_udp_port,

    input  logic [63:0] s_tdata,
    input  logic [7:0]  s_tkeep,
    input  logic        s_tvalid,
    input  logic        s_tlast,
    output logic        s_tready,

    output logic [63:0] m_tdata,
    output logic [7:0]  m_tkeep,
    output logic        m_tvalid,
    output logic        m_tlast,
    input  logic        m_tready,

    output logic        pkt_drop   // one-cycle pulse: a packet was filtered out
);
    logic [2:0]  beat;        // beat index inside the packet, saturates at 6
    logic        drop;        // current packet failed a header check
    logic [47:0] hold_data;   // lanes 2-7 of the previous beat
    logic [5:0]  hold_keep;
    logic        flush;       // hold_* still has the packet's last bytes

    wire out_free = !m_tvalid || m_tready;
    assign s_tready = out_free && !flush;
    wire in_fire = s_tvalid && s_tready;

    function automatic [7:0] lane(input [63:0] d, input integer i);
        lane = d[8*i +: 8];
    endfunction

    // Header check for the current beat (only meaningful for beats 1, 2, 4)
    logic bad_now;
    always_comb begin
        bad_now = 1'b0;
        case (beat)
            3'd1: bad_now = {lane(s_tdata, 4), lane(s_tdata, 5)} != 16'h0800
                         || lane(s_tdata, 6) != 8'h45;
            3'd2: bad_now = ({lane(s_tdata, 4), lane(s_tdata, 5)} & 16'h3FFF) != 16'h0000
                         || lane(s_tdata, 7) != 8'd17;
            3'd4: bad_now = {lane(s_tdata, 4), lane(s_tdata, 5)} != cfg_udp_port;
            default: bad_now = 1'b0;
        endcase
    end

    always_ff @(posedge clk) begin
        pkt_drop <= 1'b0;
        if (m_tvalid && m_tready) m_tvalid <= 1'b0;

        if (rst) begin
            beat      <= '0;
            drop      <= 1'b0;
            flush     <= 1'b0;
            m_tvalid  <= 1'b0;
            hold_keep <= '0;
        end else if (flush) begin
            // Packet ended with bytes left in lanes 2-7: send them as a last beat
            if (out_free) begin
                m_tdata  <= {16'h0, hold_data};
                m_tkeep  <= {2'b00, hold_keep};
                m_tlast  <= 1'b1;
                m_tvalid <= 1'b1;
                flush    <= 1'b0;
            end
        end else if (in_fire) begin
            if (beat == 3'd5 && !drop) begin
                // First payload bytes (packet bytes 42-47): just hold them
                hold_data <= s_tdata[63:16];
                hold_keep <= s_tkeep[7:2];
                if (s_tlast) flush <= s_tkeep[2];
            end else if (beat == 3'd6 && !drop) begin
                // Output = previous lanes 2-7 followed by current lanes 0-1
                m_tdata   <= {s_tdata[15:0], hold_data};
                m_tkeep   <= {s_tkeep[1:0], hold_keep};
                m_tvalid  <= 1'b1;
                hold_data <= s_tdata[63:16];
                hold_keep <= s_tkeep[7:2];
                if (s_tlast) begin
                    m_tlast <= !s_tkeep[2];
                    flush   <= s_tkeep[2];
                end else begin
                    m_tlast <= 1'b0;
                end
            end

            if (s_tlast) begin
                pkt_drop <= drop || bad_now || beat < 3'd5;
                beat     <= '0;
                drop     <= 1'b0;
            end else begin
                beat <= (beat == 3'd6) ? beat : beat + 3'd1;
                drop <= drop || bad_now;
            end
        end
    end
endmodule
