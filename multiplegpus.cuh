// ----------------------------------------------------------------
// Multi GPU Scheduler using CUDA
// ----------------------------------------------------------------

#ifndef MGPUS_CU
#define MGPUS_CU

#include <string.h>

#include <iostream>
#include <fstream>

#include <cuda.h>
#include <cuda_runtime.h>


/**
 * @file
 * example.cu
 *
 * @brief cuda example file for single GPU workload
 */

void releasehost(float * h_A, float * h_B, float * h_C, float * h_check)
{
    // release host memory
    free(h_A);
    free(h_B);
    free(h_C);
    free(h_check);
}

void releasegpu(float * A, float * B, float * C)
{
  // release device memory
  ERROR_CHECK( cudaFree(A));
  ERROR_CHECK( cudaFree(B));
  ERROR_CHECK( cudaFree(C));
}

__global__ void mgpuMultiplyAddOperator(int n, float * A, float * B, float * C)
{
    int index = threadIdx.x + blockIdx.x * blockDim.x;

    if (index < n) {
      C[index] = (A[index] + B[index]) * 2.0f;
    }
}


void MultiGPUApplication(const int n)
{

  printf("** Multiple GPU Example with n = %d\n", n);
  printf("** Important Assumption for tests; numGPUs = 2\n");
  /* CPU data initializations */
  printf("** CPU Data Initializations -> Started\n");

  float * h_A = (float*) malloc(sizeof(float) * n);     // Host Array A
  float * h_B = (float*) malloc(sizeof(float) * n);     // Host Array B
  float * h_C = (float*) malloc(sizeof(float) * n);     // Host Array C

  float * h_check = (float*) malloc(sizeof(float) * n);   // Host Array check

  for (int i = 0; i < n; i++) {
    h_A[i] = (float) i;
    h_B[i] = (float) i;

    /*  Use to check if data is correct */
    h_check[i] = (float) (h_A[i] + h_B[i]) * 2.0f;
  }

  printf("** CPU Data Initializations -> Finished\n");

  /* CUDA event setup */
  cudaEvent_t start, stop;
  cudaEventCreate(&start);
  cudaEventCreate(&stop);

  /* CUDA event start */
  float elapsedTime;
  cudaEventRecord(start, 0);

  /* Memory Allocations */
  printf("** GPUs Data Initializations -> Started\n");

  float *A[2], *B[2], *C[2];
  const int Ns[2] = {n/2, n-(n/2)};

  // allocate the memory on the GPUs
  for(int dev=0; dev<2; dev++) {
      cudaSetDevice(dev);
      ERROR_CHECK( cudaMalloc((void**) &A[dev], Ns[dev] * sizeof(float)));
      ERROR_CHECK( cudaMalloc((void**) &B[dev], Ns[dev] * sizeof(float)));
      ERROR_CHECK( cudaMalloc((void**) &C[dev], Ns[dev] * sizeof(float)));
  }

  // Initialize device arrays with host data
  for(int dev=0,pos=0; dev<2; pos+=Ns[dev], dev++) {
      cudaSetDevice(dev);
      ERROR_CHECK( cudaMemcpyAsync( A[dev], h_A+pos, Ns[dev] * sizeof(float),
                                    cudaMemcpyHostToDevice));
      ERROR_CHECK( cudaMemcpyAsync( B[dev], h_B+pos, Ns[dev] * sizeof(float),
                                    cudaMemcpyHostToDevice));
  }

  printf("** GPUs Data Initializations -> Finished\n");

  /* Set Kernel Parameters */
  printf("** Kernel Multiply-Add Op -> Started\n");
  int threadsPerBlock = 1024;
  int blocksPerGrid = ((n + threadsPerBlock - 1) / threadsPerBlock);

  dim3 blocks  (threadsPerBlock, 1, 1);
  dim3 grid   (blocksPerGrid, 1, 1);

  for(int dev=0; dev<2; dev++) {
    cudaSetDevice(dev);
    mgpuMultiplyAddOperator<<<grid,blocks>>>(Ns[dev], A[dev], B[dev], C[dev]);
  }

  for(int dev=0,pos=0; dev<2; pos+=Ns[dev], dev++) {
      cudaSetDevice(dev);
      ERROR_CHECK( cudaMemcpyAsync( h_C+pos, C[dev], Ns[dev] * sizeof(float),
                                    cudaMemcpyDeviceToHost));
  }
  printf("** Kernel Multiply-Add Op -> Finished\n");

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&elapsedTime, start, stop);

  /* Destroy CUDA event */
  cudaEventDestroy(start);
  cudaEventDestroy(stop);

  printf("** Elapsed Time (Init + Exec) = %f (ms)\n", elapsedTime);
  /* Free Memory Allocations */
  releasehost(h_A, h_B, h_C, h_check);

  for(int gpu = 0; gpu < 2; gpu++)
    releasegpu(A[gpu], B[gpu], C[gpu]);

  return;
}

#endif // MGPUS_CU