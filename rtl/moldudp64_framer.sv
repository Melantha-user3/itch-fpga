// moldudp64_framer: splits a MoldUDP64 payload stream into ITCH messages.
//
// MoldUDP64 packet layout (big-endian):
//   bytes 0-9   session
//   bytes 10-17 sequence number of the first message
//   bytes 18-19 message count (0 = heartbeat, 0xFFFF = end of session)
//   then, per message: 2-byte length + message bytes
//
// The design keeps a byte window `win`: byte j of the window is
// win[8*j +: 8]. Every cycle it may pop a whole header or message from
// the front (a right shift) and append the incoming beat after the bytes
// that remain. Bytes at index >= cnt are always zero, so appending is an OR.
module moldudp64_framer #(
    parameter int MAX_MSG = 50,   // largest ITCH 5.0 message ('I', NOII)
    parameter int DEPTH   = 64    // window size in bytes
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
    localparam int CW = $clog2(DEPTH + 1);
    localparam logic [1:0] S_HDR = 2'd0, S_MSG = 2'd1, S_DONE = 2'd2;

    logic [8*DEPTH-1:0] win;
    logic [CW-1:0]      cnt;       // valid bytes in win
    logic [1:0]         state;
    logic               in_done;   // tlast of this packet already accepted
    logic               bad;       // error seen in this packet
    logic [63:0]        seq;       // sequence number of the next message
    logic [15:0]        remaining; // messages left in this packet

    function automatic [7:0] wbyte(input logic [8*DEPTH-1:0] w, input integer j);
        wbyte = w[8*j +: 8];
    endfunction

    // Bytes in this beat (tkeep is contiguous from lane 0)
    logic [3:0]  n_in;
    logic [63:0] in_data;
    always_comb begin
        n_in = '0;
        for (int i = 0; i < 8; i++) n_in += {3'b0, s_tkeep[i]};
        for (int i = 0; i < 8; i++) in_data[8*i +: 8] = s_tkeep[i] ? s_tdata[8*i +: 8] : 8'h00;
    end

    assign s_tready = !in_done && (state == S_DONE || cnt <= CW'(DEPTH - 8));
    wire in_fire = s_tvalid && s_tready;

    // Decide what leaves the window this cycle
    logic [15:0] blk_len;     // length field of the message at the front
    logic [15:0] hdr_count;
    logic [CW-1:0] pop;
    logic emit, to_done, err_now;
    always_comb begin
        blk_len   = {wbyte(win, 0), wbyte(win, 1)};
        hdr_count = {wbyte(win, 18), wbyte(win, 19)};
        pop     = '0;
        emit    = 1'b0;
        to_done = 1'b0;
        err_now = 1'b0;
        case (state)
            S_HDR: begin
                if (cnt >= CW'(20)) begin
                    pop = CW'(20);
                    to_done = (hdr_count == 16'h0000) || (hdr_count == 16'hFFFF);
                end else if (in_done) begin
                    err_now = 1'b1;   // packet shorter than the header
                end
            end
            S_MSG: begin
                if (cnt >= CW'(2) && (blk_len == 16'd0 || blk_len > 16'(MAX_MSG))) begin
                    err_now = 1'b1;   // impossible length: give up on this packet
                end else if (cnt >= CW'(2) && {{(16-CW){1'b0}}, cnt} >= blk_len + 16'd2) begin
                    pop  = CW'(blk_len + 16'd2);
                    emit = 1'b1;
                    to_done = (remaining == 16'd1);
                end else if (in_done) begin
                    err_now = 1'b1;   // packet ended in the middle of a message
                end
            end
            default: ;
        endcase
    end

    // Window after pop, then append the new beat right after the remaining bytes
    logic [CW-1:0]      keep_cnt;
    logic [8*DEPTH-1:0] win_next;
    always_comb begin
        keep_cnt = cnt - pop;
        win_next = win >> (8 * pop);
        if (in_fire && state != S_DONE)
            win_next = win_next | ({{(8*DEPTH-64){1'b0}}, in_data} << (8 * keep_cnt));
    end

    always_ff @(posedge clk) begin
        m_valid  <= 1'b0;
        pkt_done <= 1'b0;
        if (rst) begin
            win       <= '0;
            cnt       <= '0;
            state     <= S_HDR;
            in_done   <= 1'b0;
            bad       <= 1'b0;
            seq       <= '0;
            remaining <= '0;
            pkt_err   <= 1'b0;
        end else if (state == S_DONE) begin
            // Throw away whatever is left of the packet (padding, extra bytes)
            win <= '0;
            cnt <= '0;
            if (in_done || (in_fire && s_tlast)) begin
                state    <= S_HDR;
                in_done  <= 1'b0;
                bad      <= 1'b0;
                pkt_done <= 1'b1;
                pkt_err  <= bad;
            end
        end else if (err_now) begin
            bad   <= 1'b1;
            state <= S_DONE;
            if (in_fire && s_tlast) in_done <= 1'b1;
        end else begin
            win <= win_next;
            cnt <= keep_cnt + (in_fire ? CW'(n_in) : CW'(0));
            if (in_fire && s_tlast) in_done <= 1'b1;

            if (state == S_HDR && pop != '0) begin
                seq <= {wbyte(win, 10), wbyte(win, 11), wbyte(win, 12), wbyte(win, 13),
                        wbyte(win, 14), wbyte(win, 15), wbyte(win, 16), wbyte(win, 17)};
                remaining <= hdr_count;
                state <= to_done ? S_DONE : S_MSG;
            end

            if (emit) begin
                m_valid   <= 1'b1;
                m_seq     <= seq;
                m_len     <= blk_len[5:0];
                m_msg     <= win[8*2 +: 8*MAX_MSG];
                seq       <= seq + 64'd1;
                remaining <= remaining - 16'd1;
                if (to_done) state <= S_DONE;
            end
        end
    end
endmodule
