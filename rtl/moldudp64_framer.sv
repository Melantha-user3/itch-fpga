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
//   Control: tracks where each block starts and ends, as byte positions in
//   the packet. It only reads the two length bytes of each block, so the
//   loop "length -> next start -> next length" is one 8:1 byte mux plus an
//   adder. A block is at least 14 bytes and a beat is 8, so there is never
//   more than one block end and one block start in a beat.
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
    logic [12:0] pb;          // payload beat index of the incoming beat
    logic [1:0]  st;
    logic        in_blk;      // a block has started and not yet ended
    logic        len_pend;    // block started in lane 7: low length byte comes next beat
    logic [7:0]  len_hi;
    logic [15:0] blk_start;   // byte position of the block's length field
    logic [15:0] blk_end;     // byte position of the block's last byte
    logic [5:0]  blk_len;
    logic [5:0]  rel;         // where the message starts in the 64-byte window
    logic        ps_valid;    // next block starts in a later beat
    logic [15:0] ps_pos;
    logic [15:0] remaining;   // blocks not yet started
    logic [63:0] seq;         // sequence number of the next message
    logic [63:0] hist [7];    // hist[0] = previous beat, hist[6] = 7 beats ago

    function automatic [7:0] lane(input logic [63:0] d, input integer i);
        lane = d[8*i +: 8];
    endfunction

    // ------------------------------------------------------------ control
    logic [3:0]  nk;          // bytes in this beat
    logic        emit, err;
    logic        cand_valid, start_here, len_ready;
    logic [15:0] cand_pos, len_start, len_val, end_pos;
    logic [2:0]  ls;

    logic [1:0]  n_st;
    logic        n_in_blk, n_len_pend, n_ps_valid;
    logic [7:0]  n_len_hi;
    logic [15:0] n_blk_start, n_blk_end, n_ps_pos, n_remaining;
    logic [5:0]  n_blk_len, n_rel;
    logic [63:0] n_seq;

    always_comb begin
        nk = '0;
        for (int i = 0; i < 8; i++) nk += {3'b0, s_tkeep[i]};

        n_st = st; n_in_blk = in_blk; n_len_pend = len_pend; n_len_hi = len_hi;
        n_blk_start = blk_start; n_blk_end = blk_end; n_blk_len = blk_len; n_rel = rel;
        n_ps_valid = ps_valid; n_ps_pos = ps_pos; n_remaining = remaining; n_seq = seq;
        emit = 1'b0; err = 1'b0;
        cand_valid = 1'b0; cand_pos = '0; start_here = 1'b0; ls = '0;
        len_ready = 1'b0; len_start = '0; len_val = '0; end_pos = '0;

        if (st == ST_HDR) begin
            // Fixed positions: seq = bytes 10-17, count = bytes 18-19, first block at 20
            if (pb == 13'd1) begin
                n_seq[63:16] = {lane(s_tdata, 2), lane(s_tdata, 3), lane(s_tdata, 4),
                                lane(s_tdata, 5), lane(s_tdata, 6), lane(s_tdata, 7)};
            end else if (pb == 13'd2) begin
                n_seq[15:0] = {lane(s_tdata, 0), lane(s_tdata, 1)};
                if (nk < 4'd4) begin
                    err = 1'b1;
                end else begin
                    n_st = ST_RUN;
                    n_remaining = {lane(s_tdata, 2), lane(s_tdata, 3)};
                    if (n_remaining == 16'hFFFF) n_remaining = '0;   // end of session
                    if (n_remaining != 16'd0) begin
                        cand_valid = 1'b1;
                        cand_pos   = 16'd20;
                    end
                end
            end
        end else if (st == ST_RUN) begin
            // 1) Does the current block end in this beat?
            if (in_blk && !len_pend && blk_end[15:3] == pb) begin
                if ({1'b0, blk_end[2:0]} >= nk) begin
                    err = 1'b1;                    // packet ended inside the message
                end else begin
                    emit = 1'b1;
                    n_seq = seq + 64'd1;
                    n_in_blk = 1'b0;
                    if (remaining != 16'd0) begin
                        cand_valid = 1'b1;
                        cand_pos   = blk_end + 16'd1;
                    end
                end
            end
            if (ps_valid) begin
                cand_valid = 1'b1;
                cand_pos   = ps_pos;
            end
            // 2) Length split across beats: finish it with lane 0
            if (len_pend) begin
                n_len_pend = 1'b0;
                len_ready  = 1'b1;
                len_start  = blk_start;
                len_val    = {len_hi, lane(s_tdata, 0)};
            end
        end

        // 3) Does the next block start in this beat?
        if (cand_valid && !err) begin
            start_here = cand_pos[15:3] == pb;
            ls = cand_pos[2:0];
            if (!start_here) begin
                n_ps_valid = 1'b1;
                n_ps_pos   = cand_pos;
            end else begin
                n_ps_valid  = 1'b0;
                n_in_blk    = 1'b1;
                n_blk_start = cand_pos;
                n_remaining = n_remaining - 16'd1;
                if ({1'b0, ls} >= nk) begin
                    err = 1'b1;                    // packet ended before this block
                end else if (ls == 3'd7) begin
                    n_len_pend = 1'b1;
                    n_len_hi   = lane(s_tdata, 7);
                end else if ({1'b0, ls} + 4'd1 >= nk) begin
                    err = 1'b1;
                end else begin
                    len_ready = 1'b1;
                    len_start = cand_pos;
                    len_val   = {lane(s_tdata, 32'(ls)), lane(s_tdata, 32'(ls) + 1)};
                end
            end
        end

        // 4) Length known: work out where the block ends and where its message
        //    will sit in the window of the beat it ends in
        if (len_ready) begin
            if (len_val < 16'(MIN_MSG) || len_val > 16'(MAX_MSG)) begin
                err = 1'b1;
            end else begin
                end_pos   = len_start + 16'd1 + len_val;
                n_blk_end = end_pos;
                n_blk_len = len_val[5:0];
                // message start - 8*(end beat - 7) = len_start + 2 + 56 - 8*end beat
                n_rel     = 6'(len_start + 16'd58 - {end_pos[15:3], 3'b000});
            end
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
            pb <= '0; st <= ST_HDR; in_blk <= 1'b0; len_pend <= 1'b0;
            ps_valid <= 1'b0; remaining <= '0; seq <= '0; pkt_err <= 1'b0;
        end else if (in_fire) begin
            for (int i = 6; i > 0; i--) hist[i] <= hist[i-1];
            hist[0] <= s_tdata;

            if (emit) begin
                m_valid <= 1'b1;
                m_seq   <= seq;
                m_len   <= blk_len;
                m_msg   <= shifted[8*MAX_MSG-1:0];
            end
            if (!(st == ST_ERR || err)) seq <= n_seq;

            if (s_tlast) begin
                pkt_done <= 1'b1;
                // Good packet: no error, header complete, every block that the
                // count promised has started and ended
                pkt_err  <= (st == ST_ERR) || err || n_st == ST_HDR || n_in_blk
                            || n_len_pend || n_ps_valid || n_remaining != 16'd0;
                pb <= '0; st <= ST_HDR; in_blk <= 1'b0; len_pend <= 1'b0;
                ps_valid <= 1'b0; remaining <= '0;
            end else begin
                pb <= pb + 13'd1;
                if (st == ST_ERR || err) begin
                    st <= ST_ERR;                  // ignore the rest of this packet
                end else begin
                    st <= n_st; in_blk <= n_in_blk; len_pend <= n_len_pend; len_hi <= n_len_hi;
                    blk_start <= n_blk_start; blk_end <= n_blk_end; blk_len <= n_blk_len;
                    rel <= n_rel; ps_valid <= n_ps_valid; ps_pos <= n_ps_pos;
                    remaining <= n_remaining;
                end
            end
        end
    end
endmodule
