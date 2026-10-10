`timescale 1ns/1ps
import inr_pkg::*;

module siren_sharpen (
    input  logic              clk,
    input  logic              rst_in,
    input  logic signed [15:0] data_in,
    input  logic              valid_in,

    output logic              pixel_valid,
    output logic signed [15:0] pixel_out,
    output logic              frame_done
);

    // Control Signals & Counters
    logic        shift_en;
    logic [10:0] in_cnt;
    logic [5:0]  fill_cnt;
    logic [10:0] out_cnt;
    logic [4:0]  flush_timer;
    logic [4:0]  col_x;
    logic [4:0]  row_y;

    // Line Buffers & Pointer
    logic [15:0] line_buf_0 [0:31];
    logic [15:0] line_buf_1 [0:31];
    logic [4:0]  lb_pointer;

    // 3x3 Window Registers
    logic signed [15:0] r0_c0, r0_c1, r0_c2;
    logic signed [15:0] r1_c0, r1_c1, r1_c2;
    logic signed [15:0] r2_c0, r2_c1, r2_c2;

    typedef enum logic [1:0] {
        S_IDLE,
        S_RUN,
        S_FLUSH,
        S_DONE
    } state_t;

    state_t state, next_state;

    logic signed [15:0] lb0_dout;
    logic signed [15:0] lb1_dout;
    logic signed [15:0] ingest_pixel;

    assign lb0_dout     = line_buf_0[lb_pointer];
    assign lb1_dout     = line_buf_1[lb_pointer];
    assign ingest_pixel = (state == S_FLUSH) ? 16'sh0000 : data_in;

    always_comb begin
        shift_en   = 1'b0;
        next_state = state;

        if (state == S_IDLE || state == S_RUN) begin
            shift_en = valid_in;
        end else if (state == S_FLUSH) begin
            shift_en = (flush_timer == 5'd27);
        end else begin
            shift_en = 1'b0;
        end

        case (state)
            S_IDLE: begin
                if (valid_in) next_state = S_RUN;
            end
            S_RUN: begin
                if (shift_en && (in_cnt == 11'd1023)) next_state = S_FLUSH;
            end
            S_FLUSH: begin
                if (shift_en && (out_cnt >= 11'd1023)) next_state = S_DONE;
            end
            S_DONE: begin
                next_state = S_IDLE;
            end
            default: next_state = S_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_in) begin
        if (!rst_in) begin
            state       <= S_IDLE;
            flush_timer <= '0;
            in_cnt      <= '0;
            fill_cnt    <= '0;
            out_cnt     <= '0;
            col_x       <= '0;
            row_y       <= '0;
            lb_pointer  <= '0;
        end else begin
            state <= next_state;

            if (state == S_FLUSH) begin
                if (flush_timer == 5'd27) flush_timer <= '0;
                else flush_timer <= flush_timer + 1'b1;
            end else begin
                flush_timer <= '0;
            end

            if (shift_en) begin
                if (state == S_RUN || state == S_IDLE) in_cnt <= in_cnt + 1'b1;

                if (fill_cnt < 6'd34) begin
                    fill_cnt <= fill_cnt + 1'b1;
                end else begin
                    fill_cnt <= 6'd34;
                    if (out_cnt < 11'd1024) begin
                        out_cnt <= out_cnt + 1'b1;

                        if (col_x == 5'd31) begin
                            col_x <= '0;
                            row_y <= row_y + 1'b1;
                        end else begin
                            col_x <= col_x + 1'b1;
                        end
                    end
                end

                lb_pointer <= lb_pointer + 1'b1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_in) begin
        if (!rst_in) begin
            r0_c0 <= '0; r0_c1 <= '0; r0_c2 <= '0;
            r1_c0 <= '0; r1_c1 <= '0; r1_c2 <= '0;
            r2_c0 <= '0; r2_c1 <= '0; r2_c2 <= '0;
        end else begin
            if (shift_en) begin
                line_buf_0[lb_pointer] <= ingest_pixel;
                line_buf_1[lb_pointer] <= lb0_dout;

                r0_c2 <= r0_c1; r0_c1 <= r0_c0; r0_c0 <= lb1_dout;
                r1_c2 <= r1_c1; r1_c1 <= r1_c0; r1_c0 <= lb0_dout;
                r2_c2 <= r2_c1; r2_c1 <= r2_c0; r2_c0 <= ingest_pixel;
            end
        end
    end

    // Spatial Boundary Handling & 8-Neighbor Accumulator
    logic signed [15:0] tap_c, tap_n, tap_s, tap_w, tap_e;
    logic signed [20:0] ext_c, ext_n, ext_s, ext_w, ext_e;
    logic signed [20:0] ext_nw, ext_ne, ext_sw, ext_se;
    logic signed [20:0] card_sum, diag_sum;
    logic signed [20:0] center_mult7;
    logic signed [20:0] sharp_diff;

    always_comb begin
        tap_c = r1_c1;
        tap_n = (row_y == 5'd0)  ? tap_c : r0_c1;
        tap_s = (row_y == 5'd31) ? tap_c : r2_c1;
        tap_w = (col_x == 5'd0)  ? tap_c : r1_c2;
        tap_e = (col_x == 5'd31) ? tap_c : r1_c0;

        ext_c = 21'(signed'(tap_c));
        ext_n = 21'(signed'(tap_n));
        ext_s = 21'(signed'(tap_s));
        ext_w = 21'(signed'(tap_w));
        ext_e = 21'(signed'(tap_e));

        // Diagonal taps with boundary clamp
        ext_nw = 21'(signed'(((row_y == 5'd0)  || (col_x == 5'd0))  ? tap_c : r0_c2));
        ext_ne = 21'(signed'(((row_y == 5'd0)  || (col_x == 5'd31)) ? tap_c : r0_c0));
        ext_sw = 21'(signed'(((row_y == 5'd31) || (col_x == 5'd0))  ? tap_c : r2_c2));
        ext_se = 21'(signed'(((row_y == 5'd31) || (col_x == 5'd31)) ? tap_c : r2_c0));

        card_sum = ext_n + ext_s + ext_w + ext_e;
        diag_sum = ext_nw + ext_ne + ext_sw + ext_se;

        // 7*C - Card_Sum - 0.5*Diag_Sum
        center_mult7 = (ext_c <<< 3) - ext_c;
        sharp_diff   = center_mult7 - card_sum - (diag_sum >>> 1);
    end

    // Saturation to Q4.12 [0.0, 1.0]
    always_comb begin
        if (sharp_diff < 21'sd0) begin
            pixel_out = 16'sh0000;
        end else if (sharp_diff > 21'sd4096) begin
            pixel_out = 16'sh1000;
        end else begin
            pixel_out = 16'(sharp_diff);
        end
    end

    assign pixel_valid = (shift_en && (fill_cnt == 6'd34) && (out_cnt < 11'd1024));
    assign frame_done  = (state == S_DONE);

endmodule
