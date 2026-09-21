package inr_pkg;
    parameter int COORD_WIDTH = 16;
    parameter int COORD_FRAC  = 14;
    parameter int FMAT_WIDTH  = 16;
    parameter int FMAT_FRAC   = 14;
    parameter int WEIGHT_WIDTH= 10;
    parameter int WEIGHT_FRAC = 8;
    parameter int ACT_WIDTH   = 16;
    parameter int ACT_FRAC    = 12;
    parameter int ACCUM_WIDTH = 32;
    parameter int OUT_WIDTH   = 8;

    parameter int IN_DIM          = 3;
    parameter int FFM_PROJ_DIM    = 4;
    parameter int FFM_OUT_DIM     = 8;
    parameter int HIDDEN_DIM      = 32;
    parameter int OUT_DIM         = 1;
    parameter int NUM_PE          = 8;

    parameter int FMAT_MEM_DEPTH   = 12;
    parameter int IMEM_DEOPTH      = 8;
    parameter int NEURON_MEM_DEPTH = 32;
    parameter int WMEM_DEPTH       = (FFM_OUT_DIM * HIDDEN_DIM) + (HIDDEN_DIM * HIDDEN_DIM) + (HIDDEN_DIM * OUT_DIM);

    parameter int CORDIC_STAGES    = 16;
    parameter logic signed [15:0] CORDIC_K = 16'sh4DBA;
    parameter logic signed [255:0] CORDIC_ATAN_LUT = {
        16'sh2000, 16'sh12E4, 16'sh09FB, 16'sh0511,
        16'sh028B, 16'sh0146, 16'sh00A3, 16'sh0051,
        16'sh0029, 16'sh0014, 16'sh000A, 16'sh0005,
        16'sh0003, 16'sh0001, 16'sh0001, 16'sh0000
    };

    typedef logic signed [COORD_WIDTH-1:0] coord_t;
    typedef logic signed [FMAT_WIDTH-1:0]  fmat_t;
    typedef logic signed [WEIGHT_WIDTH-1:0] weight_t;
    typedef logic signed [ACT_WIDTH-1:0]   act_t;
    typedef logic signed [ACCUM_WIDTH-1:0] psum_t;
    typedef logic        [OUT_WIDTH-1:0]   voxel_t;

    typedef struct packed {
        coord_t x;
        coord_t y;
        coord_t z;
    } coord_vec_t;

    typedef enum logic [2:0] {
        STATE_IDLE       = 3'b000,
        STATE_LOAD_PARAMS= 3'b001,
        STATE_COMPUTE_FFM= 3'b010,
        STATE_COMPUTE_MLP= 3'b011,
        STATE_STREAM_OUT = 3'b100,
        STATE_DONE       = 3'b101
    } fsm_state;
endpackage
