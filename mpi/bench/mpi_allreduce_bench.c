#include <mpi.h>
#include <stdio.h>

int main(int argc, char **argv) {
  MPI_Init(&argc, &argv);
  int rank, np;
  MPI_Comm_rank(MPI_COMM_WORLD, &rank);
  MPI_Comm_size(MPI_COMM_WORLD, &np);

  double in = rank, out;
  const int warm = 20000, iter = 200000;
  for (int i = 0; i < warm; i++)
    MPI_Allreduce(&in, &out, 1, MPI_DOUBLE, MPI_SUM, MPI_COMM_WORLD);
  MPI_Barrier(MPI_COMM_WORLD);

  double t0 = MPI_Wtime();
  for (int i = 0; i < iter; i++)
    MPI_Allreduce(&in, &out, 1, MPI_DOUBLE, MPI_SUM, MPI_COMM_WORLD);
  double per = (MPI_Wtime() - t0) / iter * 1e9;

  double mx;
  MPI_Reduce(&per, &mx, 1, MPI_DOUBLE, MPI_MAX, 0, MPI_COMM_WORLD);
  if (!rank) printf("np=%d MPI_Allreduce(1 double): %.0f ns/op\n", np, mx);
  MPI_Finalize();
  return 0;
}
