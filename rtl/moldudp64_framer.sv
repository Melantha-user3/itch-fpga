// moldudp64_framer: splits a MoldUDP64 payload stream into ITCH messages.
//
// MoldUDP64 packet layout (big-endian):
//   bytes 0-9   session
//   bytes 10-17 sequence number of the first message
//   bytes 18-19 message count (0 = heartbeat, 0xFFFF = end of session)
//   then, per message block: 2-byte length + message bytes
//
// The design is split in two so the slow part has no feedback loop:
//
//   Control: tracks where each block starts and ends. It only reads the two
//   length bytes of each block. Positions are kept relative to the current
//   beat (which beat, which lane), not as byte addresses in the packet, so
//   the loop "length -> next start -> next length" is one 8:1 byte mux plus
//   a 6-bit add. A block is at least 14 bytes and a beat is 8, so there is
//   never more than one block end and one block start in a beat.
//
//   Data: keeps the last 7 beats. When a block ends in the current beat,
//   its message is somewhere in {current beat, last 7 beats} (64 bytes:
//   a 50-byte message ending in lane 0 starts 49 bytes back, in lane 7 of
//   the beat 7 beats ago);
//   one shifter pulls it out. The shift amount (`rel`) was worked out when
//   the block started, so it comes straight from a register.
//
// Never stalls the input: s_tready is always 1.
module moldudp64_framer #(
    parameter int MAX_MSG = 50,   // largest ITCH 5.0 message ('I', NOII)
    parameter int MIN_MSG = 12    // smallest ITCH 5.0 message ('S', 'W')
) (
    input  logic                 clk,
    input  logic                 rst,

    input  logic [63:0]          s_tdata,
    input  logic [7:0]           s_tkeep,
    input  logic                 s_tvalid,
    input  logic                 s_tlast,
    output logic                 s_tready,

    output logic                 m_valid,   // one message per pulse
    output logic [63:0]          m_seq,     // its MoldUDP64 sequence number
    output logic [5:0]           m_len,
    output logic [8*MAX_MSG-1:0] m_msg,     // message byte k at [8*k +: 8]

    output logic                 pkt_done,  // pulse at the end of every packet
    output logic                 pkt_err    // valid with pkt_done
);
    localparam logic [1:0] ST_HDR = 2'd0, ST_RUN = 2'd1, ST_ERR = 2'd2;

    assign s_tready = 1'b1;
    wire in_fire = s_tvalid;

    // ------------------------------------------------------------ registers
    // Everything the next beat needs to decide is prepared one beat early
    // (end_q, ls_q, rel), so the per-beat loop stays short.
    logic [1:0]  hb;          // header beat 0, 1, 2
    logic [1:0]  st;
    logic        in_blk;      // a block has started and not yet ended
    logic        len_pend;    // block started in lane 7: low length byte comes next beat
    logic [7:0]  len_hi;
    logic [2:0]  bl;          // beats from this beat until the block's last beat
    logic        end_q;       // this beat holds the block's last byte (bl == 0)
    logic [2:0]  end_lane;    // lane of the block's last byte
    logic [2:0]  ls_q;        // lane where the next block starts (after end_lane)
    logic [2:0]  a_q;         // ls_q + 1
    logic [5:0]  blk_len;
    logic [5:0]  rel;         // where the message starts in the 64-byte window
    logic        more;        // more blocks to start after the current one
    logic        ps_valid;    // previous block ended in lane 7: next starts at lane 0
    logic [15:0] remaining;   // blocks not yet started
    logic [15:0] len_full_q;  // last length field read, checked one beat later
    logic        len_chk_q;
    logic [63:0] seq;         // sequence number of the next message
    logic [63:0] hist [7];    // hist[0] = previous beat, hist[6] = 7 beats ago

    function automatic [7:0] lane(input logic [63:0] d, input integer i);
        lane = d[8*i +: 8];
    endfunction

    // ------------------------------------------------------------ control
    logic        end_now, emit, err, len_bad;
    logic        start_here, len_ready;
    logic [2:0]  ls;          // lane where the next block starts
    logic [2:0]  a;           // (lane of the length field) + 1, relative to this beat
    logic [15:0] len_val;
    logic [5:0]  end_rel;     // last byte of the block, counted from lane 0 of this beat
    logic [15:0] count;

    logic [1:0]  n_st;
    logic        n_in_blk, n_len_pend, n_ps_valid, n_more, n_end_q, n_len_chk;
    logic [7:0]  n_len_hi;
    logic [2:0]  n_bl, n_end_lane, n_ls, n_a;
    logic [5:0]  n_blk_len, n_rel;
    logic [15:0] n_remaining, n_len_full;
    logic [63:0] n_seq;

    always_comb begin
        n_st = st; n_in_blk = in_blk; n_len_pend = len_pend; n_len_hi = len_hi;
        n_bl = bl; n_end_q = end_q; n_end_lane = end_lane; n_ls = ls_q; n_a = a_q;
        n_blk_len = blk_len; n_rel = rel; n_more = more; n_ps_valid = 1'b0;
        n_remaining = remaining; n_len_full = len_full_q; n_len_chk = 1'b0;
        n_seq = seq;
        end_now = 1'b0; emit = 1'b0; err = 1'b0;
        start_here = 1'b0; ls = ls_q; len_ready = 1'b0;
        end_rel = '0;
        count = {lane(s_tdata, 2), lane(s_tdata, 3)};

        // Length read last beat out of range: give up on this packet
        len_bad = len_chk_q && (len_full_q < 16'(MIN_MSG) || len_full_q > 16'(MAX_MSG));
        if (len_bad) err = 1'b1;

        if (st == ST_HDR) begin
            // Fixed positions: seq = bytes 10-17, count = bytes 18-19, first block at 20
            if (hb == 2'd1) begin
                n_seq[63:16] = {lane(s_tdata, 2), lane(s_tdata, 3), lane(s_tdata, 4),
                                lane(s_tdata, 5), lane(s_tdata, 6), lane(s_tdata, 7)};
            end else if (hb == 2'd2) begin
                n_seq[15:0] = {lane(s_tdata, 0), lane(s_tdata, 1)};
                n_st = ST_RUN;
                if (!s_tkeep[3]) err = 1'b1;
                if (count != 16'd0 && count != 16'hFFFF) begin   // else heartbeat / end of session
                    start_here  = 1'b1;               // byte 20 = beat 2, lane 4
                    ls          = 3'd4;
                    n_remaining = count - 16'd1;
                    n_more      = count != 16'd1;
                end else begin
                    n_remaining = '0;
                end
            end
        end else if (st == ST_RUN) begin
            // 1) The current block ends in this beat
            end_now = in_blk && end_q;
            if (end_now) begin
                emit = s_tkeep[end_lane] && !len_bad;
                if (!s_tkeep[end_lane]) err = 1'b1;  // packet ended inside the message
                n_seq = seq + 64'd1;
                n_in_blk = 1'b0;
                n_end_q = 1'b0;
                if (more) begin
                    if (end_lane == 3'd7) n_ps_valid = 1'b1;   // starts at lane 0 next beat
                    else                  start_here = 1'b1;   // starts at ls_q this beat
                end
            end else if (in_blk && !len_pend) begin
                n_bl    = bl - 3'd1;
                n_end_q = bl == 3'd1;
            end
            if (ps_valid) start_here = 1'b1;          // ls_q is 0 here
            if (start_here) begin
                n_remaining = remaining - 16'd1;
                n_more      = remaining != 16'd1;
            end
            // 2) Length field split across beats: finish it with lane 0.
            //    The length field started one byte before this beat, so a = 0.
            if (len_pend) begin
                n_len_pend = 1'b0;
                len_ready  = 1'b1;
            end
        end

        // 3) A block starts in this beat, at lane ls
        if (start_here) begin
            n_in_blk = 1'b1;
            if (!s_tkeep[ls]) err = 1'b1;          // packet ended before this block
            if (ls == 3'd7) begin
                n_len_pend = 1'b1;
                n_len_hi   = lane(s_tdata, 7);
            end else begin
                if (!s_tkeep[ls + 3'd1]) err = 1'b1;
                len_ready = 1'b1;
            end
        end

        // The length value and its offset `a` are picked only by registers
        // (st, len_pend, ls_q), never by this beat's decisions, so the mux
        // can start as soon as the data arrives.
        if (len_pend) begin
            a       = 3'd0;                         // field started one byte before this beat
            len_val = {len_hi, lane(s_tdata, 0)};
        end else if (st == ST_HDR) begin
            a       = 3'd5;                         // first block: length in lanes 4-5
            len_val = {lane(s_tdata, 4), lane(s_tdata, 5)};
        end else begin
            a       = a_q;
            len_val = {lane(s_tdata, 32'(ls_q)), lane(s_tdata, 32'(ls_q) + 1)};
        end

        // 4) Length known. Block = length field + message, so its last byte is
        //    at end_rel = a + len (from lane 0 of this beat): k = end_rel/8 beats
        //    later, lane end_rel%8. The message starts at a + 1, which in the
        //    window of the end beat is a + 1 - 8*(k - 7) = 57 - len + end lane.
        //    The range check on len happens next beat (len_bad).
        if (len_ready) begin
            end_rel    = {3'b000, a} + len_val[5:0];
            n_bl       = end_rel[5:3] - 3'd1;      // >= 1 beat later since len >= 12
            n_end_q    = end_rel[5:3] == 3'd1;
            n_end_lane = end_rel[2:0];
            n_ls       = end_rel[2:0] + 3'd1;      // wraps to 0 when the block ends in lane 7
            n_a        = end_rel[2:0] + 3'd2;
            n_blk_len  = len_val[5:0];
            n_rel      = 6'd57 - len_val[5:0] + {3'b000, end_rel[2:0]};
            n_len_full = len_val;
            n_len_chk  = 1'b1;
        end
    end

    // ------------------------------------------------------------ data
    wire  [511:0] window = {s_tdata, hist[0], hist[1], hist[2], hist[3], hist[4], hist[5], hist[6]};
    logic [511:0] shifted;
    assign shifted = window >> {rel, 3'b000};

    always_ff @(posedge clk) begin
        m_valid  <= 1'b0;
        pkt_done <= 1'b0;
        if (rst) begin
            hb <= '0; st <= ST_HDR; in_blk <= 1'b0; len_pend <= 1'b0;
            ps_valid <= 1'b0; remaining <= '0; seq <= '0; pkt_err <= 1'b0;
            len_chk_q <= 1'b0; end_q <= 1'b0;
        end else if (in_fire) begin
            for (int i = 6; i > 0; i--) hist[i] <= hist[i-1];
            hist[0] <= s_tdata;

            if (emit) begin
                m_valid <= 1'b1;
                m_seq   <= seq;
                m_len   <= blk_len;
                m_msg   <= shifted[8*MAX_MSG-1:0];
            end
            seq <= n_seq;

            if (s_tlast) begin
                pkt_done <= 1'b1;
                // Good packet: no error, header complete, every block that the
                // count promised has started and ended
                pkt_err  <= (st == ST_ERR) || err || n_st == ST_HDR || n_in_blk
                            || n_len_pend || n_ps_valid || n_remaining != 16'd0;
                hb <= '0; st <= ST_HDR; in_blk <= 1'b0; len_pend <= 1'b0;
                ps_valid <= 1'b0; remaining <= '0; len_chk_q <= 1'b0; end_q <= 1'b0;
            end else begin
                if (hb != 2'd3) hb <= hb + 2'd1;
                // After an error only `st` matters: ST_ERR ignores the rest of
                // the packet, so the other registers may take any value. Not
                // gating them with `err` keeps the length check off their
                // enable path.
                st <= (st == ST_ERR || err) ? ST_ERR : n_st;
                in_blk <= n_in_blk; len_pend <= n_len_pend; len_hi <= n_len_hi;
                bl <= n_bl; end_q <= n_end_q; end_lane <= n_end_lane; ls_q <= n_ls; a_q <= n_a;
                blk_len <= n_blk_len; rel <= n_rel; more <= n_more; ps_valid <= n_ps_valid;
                remaining <= n_remaining; len_full_q <= n_len_full; len_chk_q <= n_len_chk;
            end
        end
    end
endmodule
