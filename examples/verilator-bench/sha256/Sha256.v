// Sha256.v — single-block SHA-256, one round per cycle.
// Takes 64 cycles + a few overhead cycles to hash one block.
// Standard test vector: SHA-256("abc") = ba7816bf 8f01cfea ...

module Sha256 (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [511:0] block,        // input message block
    output reg          done,
    output reg  [255:0] digest         // {h0,h1,...,h7}
);
    function [31:0] CH;  input [31:0] x,y,z; CH = (x & y) ^ ((~x) & z); endfunction
    function [31:0] MAJ; input [31:0] x,y,z; MAJ = (x & y) ^ (x & z) ^ (y & z); endfunction
    function [31:0] EP0; input [31:0] x;
        EP0 = {x[1:0],x[31:2]} ^ {x[12:0],x[31:13]} ^ {x[21:0],x[31:22]};
    endfunction
    function [31:0] EP1; input [31:0] x;
        EP1 = {x[5:0],x[31:6]} ^ {x[10:0],x[31:11]} ^ {x[24:0],x[31:25]};
    endfunction
    function [31:0] SIG0; input [31:0] x;
        SIG0 = {x[6:0],x[31:7]} ^ {x[17:0],x[31:18]} ^ (x >> 3);
    endfunction
    function [31:0] SIG1; input [31:0] x;
        SIG1 = {x[16:0],x[31:17]} ^ {x[18:0],x[31:19]} ^ (x >> 10);
    endfunction

    // K constants
    reg [31:0] K [0:63];
    initial begin
        K[ 0]=32'h428a2f98; K[ 1]=32'h71374491; K[ 2]=32'hb5c0fbcf; K[ 3]=32'he9b5dba5;
        K[ 4]=32'h3956c25b; K[ 5]=32'h59f111f1; K[ 6]=32'h923f82a4; K[ 7]=32'hab1c5ed5;
        K[ 8]=32'hd807aa98; K[ 9]=32'h12835b01; K[10]=32'h243185be; K[11]=32'h550c7dc3;
        K[12]=32'h72be5d74; K[13]=32'h80deb1fe; K[14]=32'h9bdc06a7; K[15]=32'hc19bf174;
        K[16]=32'he49b69c1; K[17]=32'hefbe4786; K[18]=32'h0fc19dc6; K[19]=32'h240ca1cc;
        K[20]=32'h2de92c6f; K[21]=32'h4a7484aa; K[22]=32'h5cb0a9dc; K[23]=32'h76f988da;
        K[24]=32'h983e5152; K[25]=32'ha831c66d; K[26]=32'hb00327c8; K[27]=32'hbf597fc7;
        K[28]=32'hc6e00bf3; K[29]=32'hd5a79147; K[30]=32'h06ca6351; K[31]=32'h14292967;
        K[32]=32'h27b70a85; K[33]=32'h2e1b2138; K[34]=32'h4d2c6dfc; K[35]=32'h53380d13;
        K[36]=32'h650a7354; K[37]=32'h766a0abb; K[38]=32'h81c2c92e; K[39]=32'h92722c85;
        K[40]=32'ha2bfe8a1; K[41]=32'ha81a664b; K[42]=32'hc24b8b70; K[43]=32'hc76c51a3;
        K[44]=32'hd192e819; K[45]=32'hd6990624; K[46]=32'hf40e3585; K[47]=32'h106aa070;
        K[48]=32'h19a4c116; K[49]=32'h1e376c08; K[50]=32'h2748774c; K[51]=32'h34b0bcb5;
        K[52]=32'h391c0cb3; K[53]=32'h4ed8aa4a; K[54]=32'h5b9cca4f; K[55]=32'h682e6ff3;
        K[56]=32'h748f82ee; K[57]=32'h78a5636f; K[58]=32'h84c87814; K[59]=32'h8cc70208;
        K[60]=32'h90befffa; K[61]=32'ha4506ceb; K[62]=32'hbef9a3f7; K[63]=32'hc67178f2;
    end

    // State a..h, ring of last 16 W values, round counter
    reg [31:0] a,b,c,d,e,f,g,h;
    reg [31:0] w [0:15];
    reg [31:0] h0,h1,h2,h3,h4,h5,h6,h7;
    reg [6:0]  r;
    reg        busy;

    integer i;

    wire [31:0] w_new = (r >= 16) ?
        SIG1(w[(r-2)&15]) + w[(r-7)&15] + SIG0(w[(r-15)&15]) + w[r&15]
        : w[r&15];

    wire [31:0] t1 = h + EP1(e) + CH(e,f,g) + K[r[5:0]] + w_new;
    wire [31:0] t2 = EP0(a) + MAJ(a,b,c);

    always @(posedge clk) begin
        if (rst) begin
            busy <= 0; done <= 0; r <= 0;
        end else if (start && !busy) begin
            // Each call is an INDEPENDENT hash of `block` — load running state
            // and accumulator with the standard SHA-256 IV every time.
            for (i = 0; i < 16; i = i + 1)
                w[i] <= block[(i*32) +: 32];
            a  <= 32'h6a09e667; b  <= 32'hbb67ae85;
            c  <= 32'h3c6ef372; d  <= 32'ha54ff53a;
            e  <= 32'h510e527f; f  <= 32'h9b05688c;
            g  <= 32'h1f83d9ab; h  <= 32'h5be0cd19;
            h0 <= 32'h6a09e667; h1 <= 32'hbb67ae85;
            h2 <= 32'h3c6ef372; h3 <= 32'ha54ff53a;
            h4 <= 32'h510e527f; h5 <= 32'h9b05688c;
            h6 <= 32'h1f83d9ab; h7 <= 32'h5be0cd19;
            r <= 0; busy <= 1; done <= 0;
        end else if (busy) begin
            if (r >= 16) w[r&15] <= w_new;
            h <= g; g <= f; f <= e; e <= d + t1;
            d <= c; c <= b; b <= a; a <= t1 + t2;
            if (r == 63) begin
                // Final accumulation. Digest is delivered in the SAME cycle
                // as `done` goes high, computed from the round-63 t1/t2 with
                // current a..h treated as pre-update.
                h0 <= h0 + (t1 + t2);
                h1 <= h1 + a;
                h2 <= h2 + b;
                h3 <= h3 + c;
                h4 <= h4 + (d + t1);
                h5 <= h5 + e;
                h6 <= h6 + f;
                h7 <= h7 + g;
                digest <= { h0 + (t1 + t2),
                            h1 + a,
                            h2 + b,
                            h3 + c,
                            h4 + (d + t1),
                            h5 + e,
                            h6 + f,
                            h7 + g };
                busy <= 0; done <= 1;
            end
            r <= r + 1;
        end else begin
            done <= 0;
        end
    end
endmodule
