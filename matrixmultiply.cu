#include <cuda.h>
#include <cuda_runtime.h>
#include <omp.h>
#include <iostream>
#include <thread>
#include <fstream>
#include <algorithm>

#include "matrixmultiply.cuh"
#include "scheduler.cuh"

#define BLOCK_WIDTH 8

/**
* @brief Macro for error checking for all GPU calls
* @param[in] ans	The GPU call itself, which evaluates to the cudaError_t returned.
*/
#ifndef ERROR_CHECK
#define ERROR_CHECK(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file,
  int line, bool abort = true)
{
  if (code != cudaSuccess)
  {
    fprintf(stderr, "Cuda error in file '%s' in line '%d': %s\n",
      file, line, cudaGetErrorString(code));
    if (abort) exit(code);
  }
}
#endif

__global__ void GPUMatrixMultiply(const int WIDTH, float * A, float * B, float * C)
{
    // __shared__ float sh_A [BLOCK_WIDTH][BLOCK_WIDTH];
    // __shared__ float sh_B [BLOCK_WIDTH][BLOCK_WIDTH];
    //
    // unsigned int col = BLOCK_WIDTH * blockIdx.x + threadIdx.x;
    // unsigned int row = BLOCK_WIDTH * blockIdx.y + threadIdx.y;
    //
    // #pragma unroll
    // for (int m = 0; m < WIDTH/BLOCK_WIDTH; m++)
    // {
    //     sh_A[threadIdx.y][threadIdx.x] = A[row*WIDTH + (m*BLOCK_WIDTH + threadIdx.x)];
    //     sh_B[threadIdx.y][threadIdx.x] = B[(m*BLOCK_WIDTH + threadIdx.y) * WIDTH + col];
    //  __syncthreads();
    //
    //   for (int k = 0; k < BLOCK_WIDTH; k++) {
    //     C[row*WIDTH + col]+= sh_A[threadIdx.x][k] * sh_B[k][threadIdx.y];
    //   }
    //  __syncthreads();
    // }

    int col = blockDim.x*blockIdx.x + threadIdx.x;
    int row = blockDim.y*blockIdx.y + threadIdx.y;

    if((col < WIDTH) && (row < WIDTH)) {
        C[col*WIDTH + row] = A[col*WIDTH + row] + B[col*WIDTH + row];
    }
}

__global__ void MemSetKernel(const int n, float * C) {
  unsigned int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < n) C[index] = 0.0f;
}


void MatrixMultiply::FreeHostMemory()
{
  for (int i = 0; i < m_vectorSize; i++) {
    if (m_hA[i]) free(m_hA[i]);
    if (m_hB[i]) free(m_hB[i]);
    if (m_hC[i]) free(m_hC[i]);
    if (m_hCheckC[i]) free(m_hCheckC[i]);
  }
  m_hA = m_hB = m_hC = m_hCheckC = NULL;
}

void MatrixMultiply::FreeDeviceMemory()
{
  if (m_dA) ERROR_CHECK(cudaFree(m_dA));
  if (m_dB) ERROR_CHECK(cudaFree(m_dB));
  if (m_dC) ERROR_CHECK(cudaFree(m_dC));
  m_dA = m_dB = m_dC = NULL;
}

float ** MatrixMultiply::CreateMatrix(int m, int n)
{
    int i;
    float ** Matrix;
    Matrix = (float **) malloc((size_t)(m * sizeof(float*)));
    Matrix[0] = (float *) malloc((size_t)((m*n) * sizeof(float)));
    for (i=1; i<=m; i++) {
        Matrix[i] = Matrix[i-1] + n;
    }
    return Matrix;
}

/**
* @brief Initialize host vectors for a single MatrixMultiply run.
* @param[in] vectorSize	The size of each vector.
*/
void MatrixMultiply::InitializeData(int vectorSize, int threadsPerBlock, int kernelNum)
{
  m_vectorSize = vectorSize;
  m_kernelNum = kernelNum;

  // Malloc n * n memory on host to store the matrix
  m_hA =      CreateMatrix(vectorSize, vectorSize);
  m_hB =      CreateMatrix(vectorSize, vectorSize);
  m_hC =      CreateMatrix(vectorSize, vectorSize);
  m_hCheckC = CreateMatrix(vectorSize, vectorSize);

  m_blocksRequired = vectorSize % threadsPerBlock == 0 ? (vectorSize / threadsPerBlock) : 1 + (vectorSize / threadsPerBlock);
  m_globalMemRequired = 3 * sizeof(float) * vectorSize * vectorSize;

  ERROR_CHECK(cudaStreamCreate(&m_stream));
  ERROR_CHECK(cudaEventCreate(&m_startQueueEvent));
  ERROR_CHECK(cudaEventCreate(&m_startExecEvent));
  ERROR_CHECK(cudaEventCreate(&m_finishExecEvent));
  ERROR_CHECK(cudaEventCreate(&m_startCudaMallocEvent));
  ERROR_CHECK(cudaEventCreate(&m_finishDownloadEvent));

  // Fill in A and B with random numbers (should be seeded prior to call)
  float invRandMax = 1000.0f / RAND_MAX; // Produces random numbers between 0 and 1000
  for (int n = 0; n < vectorSize; ++n)
  {
    for (int m = 0; m < vectorSize; m++) {
      /* code */
      m_hA[n][m] = std::rand() * invRandMax;
      m_hB[n][m] = std::rand() * invRandMax;

      m_hCheckC[n][m] = 0.0f; // Init to 0
    }
  }

  for (int x = 0; x < vectorSize; x++) {
    for (int y = 0; y < vectorSize; y++) {
      for (int z = 0; z < vectorSize; z++) {
          m_hCheckC[x][y] += m_hA[x][z] * m_hB[z][y];
      }
    }
  }

}

/**
* @brief Find a device with enough resources, and if available, decrement the available resources and return the id.
*/
int MatrixMultiply::AcquireDeviceResources(std::vector< DeviceInfo > *deviceInfo)
{
  // Lock this method
  std::lock_guard< std::mutex > guard(m_deviceInfoMutex); // Automatically unlocks when destroyed

  int deviceNum, freeDeviceNum = -1;
  for (deviceNum = 0; deviceNum < (int)deviceInfo->size(); ++deviceNum)
  {
    DeviceInfo &device = deviceInfo->operator[](deviceNum);
    if (m_globalMemRequired < device.m_remainingGlobalMem && m_blocksRequired < device.m_remainingBlocksDimX)
    {
      freeDeviceNum = deviceNum;
      device.m_remainingGlobalMem -= m_globalMemRequired;
      device.m_remainingBlocksDimX -= m_blocksRequired;
      break;
    }
  }

  return freeDeviceNum;
}

/**
* @brief Execution is complete, release the GPU resources for other threads.
*/
void MatrixMultiply::ReleaseDeviceResources(std::vector< DeviceInfo > *deviceInfo)
{
  // Lock this method
  std::lock_guard< std::mutex > guard(m_deviceInfoMutex); // Automatically unlocks when destroyed

  if (Scheduler::m_verbose) std::cout << "** Kernel " << m_kernelNum << " released GPU " << m_deviceNum << " **\n";

  DeviceInfo &device = deviceInfo->operator[](m_deviceNum);
  device.m_remainingGlobalMem += m_globalMemRequired;
  device.m_remainingBlocksDimX += m_blocksRequired;

  // Result is already in host memory, so free GPU memory
  FreeDeviceMemory();
}

/**
* @brief Execution is complete. Record completion event and timers, verify result, and free host memory.
*/
void MatrixMultiply::FinishHostExecution()
{
  // Update timers
  ERROR_CHECK(cudaEventElapsedTime(&m_queueTimeMS, m_startQueueEvent, m_startCudaMallocEvent));
  ERROR_CHECK(cudaEventElapsedTime(&m_kernelExecTimeMS, m_startExecEvent, m_finishExecEvent));
  ERROR_CHECK(cudaEventElapsedTime(&m_totalExecTimeMS, m_startCudaMallocEvent, m_finishDownloadEvent));

  // Verify the result - In current OpenMP version this is blocking other threads, so increasing Queue time..
  bool correct(true);
  for (int n = 0; n < m_vectorSize; ++n)
  {
    for (int m = 0; m < m_vectorSize; m++) {
      correct = correct && (m_hC[n][m] == m_hCheckC[n][m]);
    }
  }

  if (Scheduler::m_verbose) printf("Kernel %d >> Device: %d, Queue: %.3fms, Kernel: %.3fms, Total: %.3fms, Correct: %s\n",
        m_kernelNum, m_deviceNum, m_queueTimeMS, m_kernelExecTimeMS, m_totalExecTimeMS, correct ? "True" : "False");

  // Free memory
  FreeHostMemory();
}

/**
* @brief Generate data for the entire batch of MatrixMultiply's being run.
*/
void BatchMatrixMultiply::GenerateData()
{
  m_data.resize(m_batchSize);

  // Get a random generator with a normal distribution, mean = meanVectorSize, stdDev = 0.1*meanVectorSize
  std::normal_distribution< float > normalDist((float)m_meanVectorSize, 0.1f*m_meanVectorSize);

  // Seed by the batch size for both the std::rand generator and the std::default_random_engine, used by distribution
  std::srand(m_batchSize);
  std::default_random_engine randomGen(m_batchSize);

  if (Scheduler::m_verbose) std::cout << "** Generating data **\n\tBatch Size: " << m_batchSize << ", Vector Size: "
            << m_meanVectorSize << ", Threads Per Block: " << m_threadsPerBlock << "\n";

  for (int kernelNum = 0; kernelNum < m_batchSize; ++kernelNum)
  {
    m_data[kernelNum] = new MatrixMultiply;
    m_data[kernelNum]->InitializeData((int)normalDist(randomGen), m_threadsPerBlock, kernelNum);
  }

  if (Scheduler::m_verbose) std::cout << "** Done generating data **\n\n";
}

void BatchMatrixMultiply::ComputeBatchResults()
{
  // Use queue times to find which kernel was run first, and which last.
  struct MatrixMultiplyComp
  {
    bool operator()(const MatrixMultiply *lhs, const MatrixMultiply *rhs)
    {
      return lhs->m_queueTimeMS < rhs->m_queueTimeMS;
    }
  };

  std::sort(m_data.begin(), m_data.end(), MatrixMultiplyComp());

  m_batchKernelExecTimeMS = m_batchTotalExecTimeMS = -1;
  if (m_data.size() < 2)
    return;

  const MatrixMultiply &firstKernel = **m_data.begin();
  const MatrixMultiply &lastKernel = **m_data.rbegin();
  ERROR_CHECK(cudaEventElapsedTime(&m_batchKernelExecTimeMS, firstKernel.m_startExecEvent, lastKernel.m_finishExecEvent));
  ERROR_CHECK(cudaEventElapsedTime(&m_batchTotalExecTimeMS, firstKernel.m_startCudaMallocEvent, lastKernel.m_finishDownloadEvent));
}

void BatchMatrixMultiply::OutputResultsCSV(const std::string &kernelName)
{
  // First output data for each kernel
  std::string filenameKernel = kernelName + std::string("KernelResults.csv");

  // Append in case running from a script (without, file is overwritten)
  std::ofstream csvKernelFile;
  csvKernelFile.open(filenameKernel.c_str(), std::ios::app);

  // Only output header if file is empty
  csvKernelFile.seekp(0, std::ios_base::beg);
  std::size_t posFirst = csvKernelFile.tellp();
  csvKernelFile.seekp(0, std::ios_base::end);
  std::size_t posLast = csvKernelFile.tellp();
  if (posLast-posFirst == 0)
  {
    csvKernelFile << "BatchSize, KernelName, MeanVectorSize, ThreadsPerBlock, MaxDevices";
    csvKernelFile << ", MaxGPUsPerKernel, KernelNum, QueueTimeMS, KernelExecTimeMS, TotalExecTimeMS\n";
  }

  for (int kernelNum = 0; kernelNum < (int)m_data.size(); ++kernelNum)
  {
    const MatrixMultiply &kernel = *m_data[kernelNum];
    csvKernelFile << m_batchSize << ", " << kernelName.c_str() << ", " << m_meanVectorSize << ", " << m_threadsPerBlock;
    csvKernelFile << ", " << Scheduler::m_maxDevices << ", " << Scheduler::m_maxGPUsPerKernel << ", " << kernel.m_kernelNum;
    csvKernelFile << ", " << kernel.m_queueTimeMS << ", " << kernel.m_kernelExecTimeMS;
    csvKernelFile << ", " << kernel.m_totalExecTimeMS << "\n";
  }

  // Second output data summary for this batch run
  std::string filenameBatch = kernelName + std::string("BatchResults.csv");

  // Append in case running from a script (without, file is overwritten)
  std::ofstream csvBatchFile;
  csvBatchFile.open(filenameBatch.c_str(), std::ios::app);

  // Only output header if file is empty
  csvBatchFile.seekp(0, std::ios_base::beg);
  posFirst = csvBatchFile.tellp();
  csvBatchFile.seekp(0, std::ios_base::end);
  posLast = csvBatchFile.tellp();
  if (posLast - posFirst == 0)
  {
    csvBatchFile << "BatchSize, KernelName, MeanVectorSize, ThreadsPerBlock, MaxDevices";
    csvBatchFile << ", MaxGPUsPerKernel, BatchKernelExecTimeMS, BatchTotalExecTimeMS\n";
  }

  csvBatchFile << m_batchSize << ", " << kernelName.c_str() << ", " << m_meanVectorSize << ", " << m_threadsPerBlock;
  csvBatchFile << ", " << Scheduler::m_maxDevices << ", " << Scheduler::m_maxGPUsPerKernel;
  csvBatchFile << ", " << m_batchKernelExecTimeMS << ", " << m_batchTotalExecTimeMS << "\n";
}

// NVCC having trouble parsing the std::thread() call when this is a member function, so keeping it non-member friend
void RunKernelThreaded(BatchMatrixMultiply *batch, int kernelNum)
{
  MatrixMultiply &kernel = *(batch->m_data[kernelNum]);

  // Acquire a GPU
  int deviceNum = -1;
  bool firstAttempt = true;
  while (deviceNum < 0)
  {
    if (firstAttempt)
    {
      if (Scheduler::m_verbose) std::cout << "** Kernel " << kernelNum << " queued for next available GPU **\n";
      firstAttempt = false;
    }

    // Try to acquire GPU resources (using a lock)
    deviceNum = kernel.AcquireDeviceResources(&Scheduler::m_deviceInfo);
  }

  if (Scheduler::m_verbose) std::cout << "** Kernel " << kernelNum << " acquired GPU " << deviceNum << " **\n";

  // Store the device number for use in ReleaseDeviceResources() - not strictly necessary, could be passed in
  kernel.m_deviceNum = deviceNum;

  // Mark the start total execution event
  ERROR_CHECK(cudaEventRecord(kernel.m_startCudaMallocEvent, kernel.m_stream));

  // We've got a GPU, use it
  // Allocate memory on the GPU for input and output data
  std::size_t vectorBytes(kernel.m_vectorSize * kernel.m_vectorSize * sizeof(float));
  ERROR_CHECK(cudaSetDevice(deviceNum));
  ERROR_CHECK(cudaMalloc((void**)&kernel.m_dA, vectorBytes));
  ERROR_CHECK(cudaMalloc((void**)&kernel.m_dB, vectorBytes));
  ERROR_CHECK(cudaMalloc((void**)&kernel.m_dC, vectorBytes));

  // Upload the input data for this stream
  ERROR_CHECK(cudaMemcpyAsync(kernel.m_dA, kernel.m_hA[0], vectorBytes,
    cudaMemcpyHostToDevice, kernel.m_stream));
  ERROR_CHECK(cudaMemcpyAsync(kernel.m_dB, kernel.m_hB[0], vectorBytes,
    cudaMemcpyHostToDevice, kernel.m_stream));

  // Mark the start kernel execution event
  ERROR_CHECK(cudaEventRecord(kernel.m_startExecEvent, kernel.m_stream));

  // Initialize C to 0
  dim3 blocks(batch->m_threadsPerBlock, 1, 1);
  dim3 grid(kernel.m_blocksRequired, 1, 1);
  MemSetKernel<<<grid, blocks>>>(kernel.m_vectorSize, kernel.m_dC);
  ERROR_CHECK(cudaPeekAtLastError());
  // printf("MemSetKernel Executed, all C init to 0.0f\n");

  // Run the kernel
  const int bytes(0); // = BLOCK_WIDTH*BLOCK_WIDTH;
  dim3 dimBlocks (batch->m_threadsPerBlock, batch->m_threadsPerBlock, 1);
  dim3 dimGrid ((kernel.m_vectorSize+dimBlocks.x-1)/dimBlocks.x,
                (kernel.m_vectorSize+dimBlocks.x-1)/dimBlocks.x, 1);
  GPUMatrixMultiply<<<dimGrid, dimBlocks, bytes, kernel.m_stream>>>(kernel.m_vectorSize, kernel.m_dA, kernel.m_dB, kernel.m_dC);
  ERROR_CHECK(cudaPeekAtLastError());

  // Record the time (since stream is non-zero, waits for stream to be complete)
  ERROR_CHECK(cudaEventRecord(kernel.m_finishExecEvent, kernel.m_stream));


  // Download the output data for this stream
  ERROR_CHECK(cudaMemcpyAsync(kernel.m_hC[0], kernel.m_dC, vectorBytes,
    cudaMemcpyDeviceToHost, kernel.m_stream));

  // Mark the end of total execution event
  ERROR_CHECK(cudaEventRecord(kernel.m_finishDownloadEvent, kernel.m_stream));

  // Need to synchronize before releasing resources
  ERROR_CHECK(cudaStreamSynchronize(kernel.m_stream));

  // Release the resources (using a lock)
  kernel.ReleaseDeviceResources(&Scheduler::m_deviceInfo);

  // Exiting the function terminates this thread
}

/**
* @brief Run the experiment on a large batch of MatrixMultiply kernels, by using separate CUDA streams per run.
*/
void BatchMatrixMultiply::RunExperiment(const std::string &kernelName)
{
  Scheduler::GetDeviceInfo();
  GenerateData();

  // Mark start queue events (needs to be done here, b/c CPU threads will block eachother)
  for (int kernelNum = 0; kernelNum < (int)m_data.size(); ++kernelNum)
    ERROR_CHECK(cudaEventRecord(m_data[kernelNum]->m_startQueueEvent, m_data[kernelNum]->m_stream));

  // Call each kernel instance with a std::thread object
  std::thread *threads = new std::thread[m_data.size()];
  for (int kernelNum = 0; kernelNum < (int)m_data.size(); ++kernelNum)
    threads[kernelNum] = std::thread(RunKernelThreaded, this, kernelNum);

  // Wait for all threads to finish
  for (int kernelNum = 0; kernelNum < (int)m_data.size(); ++kernelNum)
    threads[kernelNum].join();

  // Validate and print results
  if (Scheduler::m_verbose) std::cout << "\n** Kernel Results **\n";
  for (int kernelNum = 0; kernelNum < (int)m_data.size(); ++kernelNum)
  {
    m_data[kernelNum]->FinishHostExecution();
  }

  // Compute accumulated batch results
  ComputeBatchResults();

  // Record results to CSV
  OutputResultsCSV(kernelName);

  ERROR_CHECK(cudaDeviceSynchronize());
}
