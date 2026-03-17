/*
 * accel_demo.c — Example: trajectory computation using sin/cos/sqrt.
 *
 * Compile with standard RISC-V GCC, then use riscv_rewrite.py to replace
 * the math library calls with custom hardware instructions.
 *
 * Standard build:
 *   riscv64-linux-gnu-gcc -O2 -fno-builtin -o accel_demo accel_demo.c -lm
 *
 * Rewrite for hardware accelerator:
 *   python3 ../../python/riscv_rewrite.py -i accel_demo -o accel_demo.hw \
 *       -m math_accel.json
 *
 * The rewritten binary replaces:
 *   jal ra, sin@plt  →  custom_0 funct7=1 rd=fa0 rs1=fa0 (hardware sin)
 *   jal ra, cos@plt  →  custom_0 funct7=2 rd=fa0 rs1=fa0 (hardware cos)
 *   jal ra, sqrt@plt →  custom_0 funct7=3 rd=fa0 rs1=fa0 (hardware sqrt)
 */
#include <stdio.h>
#include <math.h>

/* Compute components of a projectile trajectory. */
typedef struct {
    double x, y;      /* position */
    double vx, vy;    /* velocity */
    double speed;     /* magnitude */
} trajectory_t;

trajectory_t compute_trajectory(double angle_deg, double velocity, double time)
{
    double angle = angle_deg * M_PI / 180.0;

    /* These three calls are the rewrite targets. */
    double vx = velocity * cos(angle);
    double vy = velocity * sin(angle) - 9.81 * time;
    double x = vx * time;
    double y = velocity * sin(angle) * time - 0.5 * 9.81 * time * time;
    double speed = sqrt(vx * vx + vy * vy);

    return (trajectory_t){x, y, vx, vy, speed};
}

int main(void)
{
    printf("Projectile trajectory (v=100 m/s)\n");
    printf("%5s  %5s  %10s  %10s  %10s  %10s  %10s\n",
           "angle", "time", "x", "y", "vx", "vy", "speed");
    printf("%5s  %5s  %10s  %10s  %10s  %10s  %10s\n",
           "-----", "----", "---", "---", "---", "---", "-----");

    double angles[] = {15, 30, 45, 60, 75};
    int n_angles = sizeof(angles) / sizeof(angles[0]);

    for (int a = 0; a < n_angles; a++) {
        for (double t = 0; t <= 5.0; t += 1.0) {
            trajectory_t tr = compute_trajectory(angles[a], 100.0, t);
            if (tr.y >= 0) {
                printf("%5.0f  %5.1f  %10.2f  %10.2f  %10.2f  %10.2f  %10.2f\n",
                       angles[a], t, tr.x, tr.y, tr.vx, tr.vy, tr.speed);
            }
        }
    }

    return 0;
}
