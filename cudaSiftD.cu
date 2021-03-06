//********************************************************//
// CUDA SIFT extractor by Marten Bjorkman aka Celebrandil //
//********************************************************//  

#include "cudautils.h"
#include "cudaSiftD.h"
#include "cudaSift.h"

///////////////////////////////////////////////////////////////////////////////
// Kernel configuration
///////////////////////////////////////////////////////////////////////////////

__constant__ float d_Threshold[2];
__constant__ float d_Scales[8], d_Factor;
__constant__ float d_EdgeLimit;
__constant__ int d_MaxNumPoints;

__device__ unsigned int d_PointCounter[1];
__constant__ float d_Kernel1[5]; 
__constant__ float d_Kernel2[12*16]; 

///////////////////////////////////////////////////////////////////////////////
// Lowpass filter and subsample image
///////////////////////////////////////////////////////////////////////////////
__global__ void ScaleDown(float *d_Result, float *d_Data, int width, int pitch, int height, int newpitch)
{
  __shared__ float inrow[SCALEDOWN_W+4]; 
  __shared__ float brow[5*(SCALEDOWN_W/2)];
  __shared__ int yRead[SCALEDOWN_H+4];
  __shared__ int yWrite[SCALEDOWN_H+4];
  #define dx2 (SCALEDOWN_W/2)
  const int tx = threadIdx.x;
  const int tx0 = tx + 0*dx2;
  const int tx1 = tx + 1*dx2;
  const int tx2 = tx + 2*dx2;
  const int tx3 = tx + 3*dx2;
  const int tx4 = tx + 4*dx2;
  const int xStart = blockIdx.x*SCALEDOWN_W;
  const int yStart = blockIdx.y*SCALEDOWN_H;
  const int xWrite = xStart/2 + tx;
  const float *k = d_Kernel1;
  if (tx<SCALEDOWN_H+4) {
    int y = yStart + tx - 1;
    y = (y<0 ? 0 : y);
    y = (y>=height ? height-1 : y);
    yRead[tx] = y*pitch;
    yWrite[tx] = (yStart + tx - 4)/2 * newpitch;
  }
  __syncthreads();
  int xRead = xStart + tx - 2;
  xRead = (xRead<0 ? 0 : xRead);
  xRead = (xRead>=width ? width-1 : xRead);
  for (int dy=0;dy<SCALEDOWN_H+4;dy+=5) {
    inrow[tx] = d_Data[yRead[dy+0] + xRead];
    __syncthreads();
    if (tx<dx2) 
      brow[tx0] = k[0]*(inrow[2*tx]+inrow[2*tx+4]) + k[1]*(inrow[2*tx+1]+inrow[2*tx+3]) + k[2]*inrow[2*tx+2];
    __syncthreads();
    if (tx<dx2 && dy>=4 && !(dy&1)) 
      d_Result[yWrite[dy+0] + xWrite] = k[2]*brow[tx2] + k[0]*(brow[tx0]+brow[tx4]) + k[1]*(brow[tx1]+brow[tx3]);
    if (dy<(SCALEDOWN_H+3)) {
      inrow[tx] = d_Data[yRead[dy+1] + xRead];
      __syncthreads();
      if (tx<dx2)
	brow[tx1] = k[0]*(inrow[2*tx]+inrow[2*tx+4]) + k[1]*(inrow[2*tx+1]+inrow[2*tx+3]) + k[2]*inrow[2*tx+2];
      __syncthreads();
      if (tx<dx2 && dy>=3 && (dy&1)) 
	d_Result[yWrite[dy+1] + xWrite] = k[2]*brow[tx3] + k[0]*(brow[tx1]+brow[tx0]) + k[1]*(brow[tx2]+brow[tx4]); 
    }
    if (dy<(SCALEDOWN_H+2)) {
      inrow[tx] = d_Data[yRead[dy+2] + xRead];
      __syncthreads();
      if (tx<dx2)
	brow[tx2] = k[0]*(inrow[2*tx]+inrow[2*tx+4]) + k[1]*(inrow[2*tx+1]+inrow[2*tx+3]) + k[2]*inrow[2*tx+2];
      __syncthreads();
      if (tx<dx2 && dy>=2 && !(dy&1)) 
	d_Result[yWrite[dy+2] + xWrite] = k[2]*brow[tx4] + k[0]*(brow[tx2]+brow[tx1]) + k[1]*(brow[tx3]+brow[tx0]); 
    }
    if (dy<(SCALEDOWN_H+1)) {
      inrow[tx] = d_Data[yRead[dy+3] + xRead];
      __syncthreads();
      if (tx<dx2)
	brow[tx3] = k[0]*(inrow[2*tx]+inrow[2*tx+4]) + k[1]*(inrow[2*tx+1]+inrow[2*tx+3]) + k[2]*inrow[2*tx+2];
      __syncthreads();
      if (tx<dx2 && dy>=1 && (dy&1)) 
	d_Result[yWrite[dy+3] + xWrite] = k[2]*brow[tx0] + k[0]*(brow[tx3]+brow[tx2]) + k[1]*(brow[tx4]+brow[tx1]); 
    }
    if (dy<SCALEDOWN_H) {
      inrow[tx] = d_Data[yRead[dy+4] + xRead];
      __syncthreads();
      if (tx<dx2)
	brow[tx4] = k[0]*(inrow[2*tx]+inrow[2*tx+4]) + k[1]*(inrow[2*tx+1]+inrow[2*tx+3]) + k[2]*inrow[2*tx+2];
      __syncthreads();
      if (tx<dx2 && !(dy&1)) 
	d_Result[yWrite[dy+4] + xWrite] = k[2]*brow[tx1] + k[0]*(brow[tx4]+brow[tx3]) + k[1]*(brow[tx0]+brow[tx2]); 
    }
    __syncthreads();
  }
}

__global__ void ScaleUp(float *d_Result, float *d_Data, int width, int pitch, int height, int newpitch)
{
  #define BW (SCALEUP_W/2 + 2)
  #define BH (SCALEUP_H/2 + 2)
  __shared__ float buffer[BW*BH];
  const int tx = threadIdx.x;
  const int ty = threadIdx.y;
  if (tx<BW && ty<BH) {
    int x = min(max(blockIdx.x*(SCALEUP_W/2) + tx - 1, 0), width-1);
    int y = min(max(blockIdx.y*(SCALEUP_H/2) + ty - 1, 0), height-1);
    buffer[ty*BW + tx] = d_Data[y*pitch + x];
  }
  __syncthreads();
  int x = blockIdx.x*SCALEUP_W + tx;
  int y = blockIdx.y*SCALEUP_H + ty;
  if (x<2*width && y<2*height) {
    int bx = (tx + 1)/2;
    int by = (ty + 1)/2;
    int bp = by*BW + bx;
    float wx = 0.25f + (tx&1)*0.50f;
    float wy = 0.25f + (ty&1)*0.50f;
    d_Result[y*newpitch + x] = wy*(wx*buffer[bp] + (1.0f-wx)*buffer[bp+1]) +
      (1.0f-wy)*(wx*buffer[bp+BW] + (1.0f-wx)*buffer[bp+BW+1]);
  }
}

__global__ void ExtractSiftDescriptors(cudaTextureObject_t texObj, SiftPoint *d_sift, int fstPts, float subsampling)
{
  __shared__ float gauss[16];
  __shared__ float buffer[128];
  __shared__ float sums[4];

  const int tx = threadIdx.x; // 0 -> 16
  const int ty = threadIdx.y; // 0 -> 8
  const int idx = ty*16 + tx;
  const int bx = blockIdx.x + fstPts;  // 0 -> numPts
  if (ty==0)
    gauss[tx] = exp(-(tx-7.5f)*(tx-7.5f)/128.0f);
  buffer[idx] = 0.0f;
  __syncthreads();

  // Compute angles and gradients
  float theta = 2.0f*3.1415f/360.0f*d_sift[bx].orientation;
  float sina = sinf(theta);           // cosa -sina
  float cosa = cosf(theta);           // sina  cosa
  float scale = 12.0f/16.0f*d_sift[bx].scale;
  float ssina = scale*sina; 
  float scosa = scale*cosa;

  for (int y=ty;y<16;y+=8) {
    float xpos = d_sift[bx].xpos + (tx-7.5f)*scosa - (y-7.5f)*ssina;
    float ypos = d_sift[bx].ypos + (tx-7.5f)*ssina + (y-7.5f)*scosa;
    float dx = tex2D<float>(texObj, xpos+cosa, ypos+sina) - 
      tex2D<float>(texObj, xpos-cosa, ypos-sina);
    float dy = tex2D<float>(texObj, xpos-sina, ypos+cosa) - 
      tex2D<float>(texObj, xpos+sina, ypos-cosa);
    float grad = gauss[y]*gauss[tx] * sqrtf(dx*dx + dy*dy);
    float angf = 4.0f/3.1415f*atan2f(dy, dx) + 4.0f;
    
    int hori = (tx + 2)/4 - 1;      // Convert from (tx,y,angle) to bins      
    float horf = (tx - 1.5f)/4.0f - hori;
    float ihorf = 1.0f - horf;           
    int veri = (y + 2)/4 - 1;
    float verf = (y - 1.5f)/4.0f - veri;
    float iverf = 1.0f - verf;
    int angi = angf;
    int angp = (angi<7 ? angi+1 : 0);
    angf -= angi;
    float iangf = 1.0f - angf;
    
    int hist = 8*(4*veri + hori);   // Each gradient measure is interpolated 
    int p1 = angi + hist;           // in angles, xpos and ypos -> 8 stores
    int p2 = angp + hist;
    if (tx>=2) { 
      float grad1 = ihorf*grad;
      if (y>=2) {   // Upper left
        float grad2 = iverf*grad1;
	atomicAdd(buffer + p1, iangf*grad2);
	atomicAdd(buffer + p2,  angf*grad2);
      }
      if (y<=13) {  // Lower left
        float grad2 = verf*grad1;
	atomicAdd(buffer + p1+32, iangf*grad2); 
	atomicAdd(buffer + p2+32,  angf*grad2);
      }
    }
    if (tx<=13) { 
      float grad1 = horf*grad;
      if (y>=2) {    // Upper right
        float grad2 = iverf*grad1;
	atomicAdd(buffer + p1+8, iangf*grad2);
	atomicAdd(buffer + p2+8,  angf*grad2);
      }
      if (y<=13) {   // Lower right
        float grad2 = verf*grad1;
	atomicAdd(buffer + p1+40, iangf*grad2);
	atomicAdd(buffer + p2+40,  angf*grad2);
      }
    }
  }
  __syncthreads();

  // Normalize twice and suppress peaks first time
  float sum = buffer[idx]*buffer[idx];
  for (int i=1;i<=16;i*=2)
    sum += __shfl_xor(sum, i);
  if ((idx&31)==0)
    sums[idx/32] = sum;
  __syncthreads();
  float tsum1 = sums[0] + sums[1] + sums[2] + sums[3]; 
  tsum1 = min(buffer[idx] * rsqrtf(tsum1), 0.2f);
  
  sum = tsum1*tsum1; 
  for (int i=1;i<=16;i*=2)
    sum += __shfl_xor(sum, i);
  if ((idx&31)==0)
    sums[idx/32] = sum;
  __syncthreads();

  float tsum2 = sums[0] + sums[1] + sums[2] + sums[3];
  float *desc = d_sift[bx].data;
  desc[idx] = tsum1 * rsqrtf(tsum2);
  if (idx==0) {
    d_sift[bx].xpos *= subsampling;
    d_sift[bx].ypos *= subsampling;
    d_sift[bx].scale *= subsampling;
  }
}
 

__global__ void ExtractSiftDescriptorsOld(cudaTextureObject_t texObj, SiftPoint *d_sift, int fstPts, float subsampling)
{
  __shared__ float gauss[16];
  __shared__ float buffer[128];
  __shared__ float sums[128];

  const int tx = threadIdx.x; // 0 -> 16
  const int ty = threadIdx.y; // 0 -> 8
  const int idx = ty*16 + tx;
  const int bx = blockIdx.x + fstPts;  // 0 -> numPts
  if (ty==0)
    gauss[tx] = exp(-(tx-7.5f)*(tx-7.5f)/128.0f);
  buffer[idx] = 0.0f;
  __syncthreads();

  // Compute angles and gradients
  float theta = 2.0f*3.1415f/360.0f*d_sift[bx].orientation;
  float sina = sinf(theta);           // cosa -sina
  float cosa = cosf(theta);           // sina  cosa
  float scale = 12.0f/16.0f*d_sift[bx].scale;
  float ssina = scale*sina; 
  float scosa = scale*cosa;

  for (int y=ty;y<16;y+=8) {
    float xpos = d_sift[bx].xpos + (tx-7.5f)*scosa - (y-7.5f)*ssina;
    float ypos = d_sift[bx].ypos + (tx-7.5f)*ssina + (y-7.5f)*scosa;
    float dx = tex2D<float>(texObj, xpos+cosa, ypos+sina) - 
      tex2D<float>(texObj, xpos-cosa, ypos-sina);
    float dy = tex2D<float>(texObj, xpos-sina, ypos+cosa) - 
      tex2D<float>(texObj, xpos+sina, ypos-cosa);
    float grad = gauss[y]*gauss[tx] * sqrtf(dx*dx + dy*dy);
    float angf = 4.0f/3.1415f*atan2f(dy, dx) + 4.0f;
    
    int hori = (tx + 2)/4 - 1;      // Convert from (tx,y,angle) to bins      
    float horf = (tx - 1.5f)/4.0f - hori;  
    float ihorf = 1.0f - horf;           
    int veri = (y + 2)/4 - 1;
    float verf = (y - 1.5f)/4.0f - veri;
    float iverf = 1.0f - verf;
    int angi = angf;
    int angp = (angi<7 ? angi+1 : 0);
    angf -= angi;
    float iangf = 1.0f - angf;
    
    int hist = 8*(4*veri + hori);   // Each gradient measure is interpolated 
    int p1 = angi + hist;           // in angles, xpos and ypos -> 8 stores
    int p2 = angp + hist;
    if (tx>=2) { 
      float grad1 = ihorf*grad;
      if (y>=2) {   // Upper left
        float grad2 = iverf*grad1;
	atomicAdd(buffer + p1, iangf*grad2);
	atomicAdd(buffer + p2,  angf*grad2);
      }
      if (y<=13) {  // Lower left
        float grad2 = verf*grad1;
	atomicAdd(buffer + p1+32, iangf*grad2); 
	atomicAdd(buffer + p2+32,  angf*grad2);
      }
    }
    if (tx<=13) { 
      float grad1 = horf*grad;
      if (y>=2) {    // Upper right
        float grad2 = iverf*grad1;
	atomicAdd(buffer + p1+8, iangf*grad2);
	atomicAdd(buffer + p2+8,  angf*grad2);
      }
      if (y<=13) {   // Lower right
        float grad2 = verf*grad1;
	atomicAdd(buffer + p1+40, iangf*grad2);
	atomicAdd(buffer + p2+40,  angf*grad2);
      }
    }
  }
  __syncthreads();

  // Normalize twice and suppress peaks first time
  if (idx<64)
    sums[idx] = buffer[idx]*buffer[idx] + buffer[idx+64]*buffer[idx+64];
  __syncthreads();      
  if (idx<32) sums[idx] = sums[idx] + sums[idx+32];
  __syncthreads();      
  if (idx<16) sums[idx] = sums[idx] + sums[idx+16];
  __syncthreads();      
  if (idx<8)  sums[idx] = sums[idx] + sums[idx+8];
  __syncthreads();      
  if (idx<4)  sums[idx] = sums[idx] + sums[idx+4];
  __syncthreads();      
  float tsum1 = sums[0] + sums[1] + sums[2] + sums[3]; 
  buffer[idx] = buffer[idx] * rsqrtf(tsum1);

  if (buffer[idx]>0.2f)
    buffer[idx] = 0.2f;
  __syncthreads();
  if (idx<64)
    sums[idx] = buffer[idx]*buffer[idx] + buffer[idx+64]*buffer[idx+64];
  __syncthreads();      
  if (idx<32) sums[idx] = sums[idx] + sums[idx+32];
  __syncthreads();      
  if (idx<16) sums[idx] = sums[idx] + sums[idx+16];
  __syncthreads();      
  if (idx<8)  sums[idx] = sums[idx] + sums[idx+8];
  __syncthreads();      
  if (idx<4)  sums[idx] = sums[idx] + sums[idx+4];
  __syncthreads();      
  float tsum2 = sums[0] + sums[1] + sums[2] + sums[3]; 

  float *desc = d_sift[bx].data;
  desc[idx] = buffer[idx] * rsqrtf(tsum2);
  if (idx==0) {
    d_sift[bx].xpos *= subsampling;
    d_sift[bx].ypos *= subsampling;
    d_sift[bx].scale *= subsampling;
  }
}
 

__global__ void RescalePositions(SiftPoint *d_sift, int numPts, float scale)
{
  int num = blockIdx.x*blockDim.x + threadIdx.x;
  if (num<numPts) {
    d_sift[num].xpos *= scale;
    d_sift[num].ypos *= scale;
    d_sift[num].scale *= scale;
  }
}


__global__ void ComputeOrientations(cudaTextureObject_t texObj, SiftPoint *d_Sift, int fstPts)
{
  __shared__ float hist[64];
  __shared__ float gauss[11];
  const int tx = threadIdx.x;
  const int bx = blockIdx.x + fstPts;
  float i2sigma2 = -1.0f/(4.5f*d_Sift[bx].scale*d_Sift[bx].scale);
  if (tx<11) 
    gauss[tx] = exp(i2sigma2*(tx-5)*(tx-5));
  if (tx<64)
    hist[tx] = 0.0f;
  __syncthreads();
  float xp = d_Sift[bx].xpos - 5.0f;
  float yp = d_Sift[bx].ypos - 5.0f;
  int yd = tx/11;
  int xd = tx - yd*11;
  float xf = xp + xd;
  float yf = yp + yd;
  if (yd<11) {
    float dx = tex2D<float>(texObj, xf+1.0, yf) - tex2D<float>(texObj, xf-1.0, yf); 
    float dy = tex2D<float>(texObj, xf, yf+1.0) - tex2D<float>(texObj, xf, yf-1.0); 
    int bin = 16.0f*atan2f(dy, dx)/3.1416f + 16.5f;
    if (bin>31)
      bin = 0;
    float grad = sqrtf(dx*dx + dy*dy);
    atomicAdd(&hist[bin], grad*gauss[xd]*gauss[yd]);
  }
  __syncthreads();
  int x1m = (tx>=1 ? tx-1 : tx+31);
  int x1p = (tx<=30 ? tx+1 : tx-31);
  if (tx<32) {
    int x2m = (tx>=2 ? tx-2 : tx+30);
    int x2p = (tx<=29 ? tx+2 : tx-30);
    hist[tx+32] = 6.0f*hist[tx] + 4.0f*(hist[x1m] + hist[x1p]) + (hist[x2m] + hist[x2p]);
  }
  __syncthreads();
  if (tx<32) {
    float v = hist[32+tx];
    hist[tx] = (v>hist[32+x1m] && v>=hist[32+x1p] ? v : 0.0f);
  }
  __syncthreads();
  if (tx==0) {
    float maxval1 = 0.0;
    float maxval2 = 0.0;
    int i1 = -1;
    int i2 = -1;
    for (int i=0;i<32;i++) {
      float v = hist[i];
      if (v>maxval1) {
	maxval2 = maxval1;
	maxval1 = v;
	i2 = i1;
	i1 = i;
      } else if (v>maxval2) {
	maxval2 = v;
	i2 = i;
      }
    }
    float val1 = hist[32+((i1+1)&31)];
    float val2 = hist[32+((i1+31)&31)];
    float peak = i1 + 0.5f*(val1-val2) / (2.0f*maxval1-val1-val2);
    d_Sift[bx].orientation = 11.25f*(peak<0.0f ? peak+32.0f : peak);
    if (maxval2>0.8f*maxval1 && false) {
      float val1 = hist[32+((i2+1)&31)];
      float val2 = hist[32+((i2+31)&31)];
      float peak = i2 + 0.5f*(val1-val2) / (2.0f*maxval2-val1-val2);
      unsigned int idx = atomicInc(d_PointCounter, 0x7fffffff);
      if (idx<d_MaxNumPoints) {
	d_Sift[idx].xpos = d_Sift[bx].xpos;
	d_Sift[idx].ypos = d_Sift[bx].ypos;
	d_Sift[idx].scale = d_Sift[bx].scale;
	d_Sift[idx].sharpness = d_Sift[bx].sharpness;
	d_Sift[idx].edgeness = d_Sift[bx].edgeness;
	d_Sift[idx].orientation = 11.25f*(peak<0.0f ? peak+32.0f : peak);;
	d_Sift[idx].subsampling = d_Sift[bx].subsampling;
      }
    } 
  }
}

__global__ void myComputeOrientations(cudaTextureObject_t texObj, SiftPoint *d_Sift, int fstPts)
{
    __shared__ float hist[64];
    __shared__ float gauss[11];
    __shared__ float texObj_share[169];
    // __shared__ cudaTextureObject_t texObj_share[169];
    const int tx = threadIdx.x;
    const int bx = blockIdx.x + fstPts;
    float i2sigma2 = -1.0f/(4.5f*d_Sift[bx].scale*d_Sift[bx].scale);

    if (tx<11)
        gauss[tx] = exp(i2sigma2*(tx-5)*(tx-5));
    if (tx<64)
        hist[tx] = 0.0f;
    __syncthreads();
    float xp = d_Sift[bx].xpos - 5.0f;
    float yp = d_Sift[bx].ypos - 5.0f;
    int yd = tx/11;
    int xd = tx - yd*11;
    //int xf = xp + xd;
    //int yf = yp + yd;



    //load texObj to SM
    int yd2=tx/13;
    int xd2=tx-yd2*13;
    float xf2=xp-1+xd2;
    float yf2=yp-1+yd2;
    texObj_share[tx]=tex2D<float>(texObj,xf2,yf2);

    __syncthreads();



    if (yd<11) {
        float dx =(float)(texObj_share[(xd+2)+(yd+1)*13] - texObj_share[(xd)+(yd+1)*13])  ;
        float dy = (float)(texObj_share[(xd+1)+(yd+2)*13] - texObj_share[(xd+1)+(yd)*13]) ;
        //float dx = tex2D<float>(texObj, xf+1.0, yf) - tex2D<float>(texObj, xf-1.0, yf);
        //float dy = tex2D<float>(texObj, xf, yf+1.0) - tex2D<float>(texObj, xf, yf-1.0);

        //float dx = tex2D<float>(texObj_share, xf+1.0, yf) - tex2D<float>(texObj_share, xf-1.0, yf);
        //float dy = tex2D<float>(texObj_share, xf, yf+1.0) - tex2D<float>(texObj_share, xf, yf-1.0);

        int bin = 16.0f*atan2f(dy, dx)/3.1416f + 16.5f;
        if (bin>31)
            bin = 0;
        float grad = sqrtf(dx*dx + dy*dy);
        atomicAdd(&hist[bin], grad*gauss[xd]*gauss[yd]);
    }
    __syncthreads();
    int x1m = (tx>=1 ? tx-1 : tx+31);
    int x1p = (tx<=30 ? tx+1 : tx-31);
    if (tx<32) {
        int x2m = (tx>=2 ? tx-2 : tx+30);
        int x2p = (tx<=29 ? tx+2 : tx-30);
        hist[tx+32] = 6.0f*hist[tx] + 4.0f*(hist[x1m] + hist[x1p]) + (hist[x2m] + hist[x2p]);
    }
    __syncthreads();
    if (tx<32) {
        float v = hist[32+tx];
        hist[tx] = (v>hist[32+x1m] && v>=hist[32+x1p] ? v : 0.0f);
    }
    __syncthreads();
    if (tx==0) {
        float maxval1 = 0.0;
        float maxval2 = 0.0;
        int i1 = -1;
        int i2 = -1;
        for (int i=0;i<32;i++) {
            float v = hist[i];
                if (v>maxval1) {
                    maxval2 = maxval1;
                    maxval1 = v;
                    i2 = i1;
                    i1 = i;
            } else if (v>maxval2) {
                        maxval2 = v;
                        i2 = i;
            }
        }
        float val1 = hist[32+((i1+1)&31)];
        float val2 = hist[32+((i1+31)&31)];
        float peak = i1 + 0.5f*(val1-val2) / (2.0f*maxval1-val1-val2);
        d_Sift[bx].orientation = 11.25f*(peak<0.0f ? peak+32.0f : peak);
        if (maxval2>0.8f*maxval1 && false) {
            float val1 = hist[32+((i2+1)&31)];
            float val2 = hist[32+((i2+31)&31)];
            float peak = i2 + 0.5f*(val1-val2) / (2.0f*maxval2-val1-val2);
            unsigned int idx = atomicInc(d_PointCounter, 0x7fffffff);
            if (idx<d_MaxNumPoints) {
                d_Sift[idx].xpos = d_Sift[bx].xpos;
                d_Sift[idx].ypos = d_Sift[bx].ypos;
                d_Sift[idx].scale = d_Sift[bx].scale;
                d_Sift[idx].sharpness = d_Sift[bx].sharpness;
                d_Sift[idx].edgeness = d_Sift[bx].edgeness;
                d_Sift[idx].orientation = 11.25f*(peak<0.0f ? peak+32.0f : peak);;
                d_Sift[idx].subsampling = d_Sift[bx].subsampling;
        }
    }
}
}

///////////////////////////////////////////////////////////////////////////////
// Subtract two images (multi-scale version)
///////////////////////////////////////////////////////////////////////////////

__global__ void FindPointsMulti(float *d_Data0, SiftPoint *d_Sift, int width, int pitch, int height, int nScales, float subsampling, float lowestScale)
{
  #define MEMWID (MINMAX_W + 2)
  __shared__ float ymin1[MEMWID], ymin2[MEMWID], ymin3[MEMWID];
  __shared__ float ymax1[MEMWID], ymax2[MEMWID], ymax3[MEMWID];
  __shared__ unsigned int cnt;
  __shared__ unsigned short points[96];

  int tx = threadIdx.x;
  int block = blockIdx.x/nScales;  //flatting the blocks
  int scale = blockIdx.x - nScales*block;  //blockIdx.x % nScales
  int minx = block*MINMAX_W;  //start point of an image of each block
  int maxx = min(minx + MINMAX_W, width); //end point of an image of each block
  int xpos = minx + tx;  //point of each thread

  int size = pitch*height;  //resize the image

  int ptr = size*scale + max(min(xpos-1, width-1), 0);  //point of each thread in DOG image
  
  if (tx==0)
    cnt = 0; 
  __syncthreads();

  int yloops = min(height - MINMAX_H*blockIdx.y, MINMAX_H);
  for (int y=0;y<yloops;y++) {

    int ypos = MINMAX_H*blockIdx.y + y;
    int yptr0 = ptr + max(0,ypos-1)*pitch;
    int yptr1 = ptr + ypos*pitch;
    int yptr2 = ptr + min(height-1,ypos+1)*pitch;
    {
      float d10 = d_Data0[yptr0];
      float d11 = d_Data0[yptr1];
      float d12 = d_Data0[yptr2];
      ymin1[tx] = fminf(fminf(d10, d11), d12);
      ymax1[tx] = fmaxf(fmaxf(d10, d11), d12);
    }
    {
      float d30 = d_Data0[yptr0 + 2*size];
      float d31 = d_Data0[yptr1 + 2*size];
      float d32 = d_Data0[yptr2 + 2*size]; 
      ymin3[tx] = fminf(fminf(d30, d31), d32);
      ymax3[tx] = fmaxf(fmaxf(d30, d31), d32);
    }
    float d20 = d_Data0[yptr0 + 1*size];
    float d21 = d_Data0[yptr1 + 1*size];
    float d22 = d_Data0[yptr2 + 1*size];
    ymin2[tx] = fminf(fminf(ymin1[tx], fminf(fminf(d20, d21), d22)), ymin3[tx]);
    ymax2[tx] = fmaxf(fmaxf(ymax1[tx], fmaxf(fmaxf(d20, d21), d22)), ymax3[tx]);
    __syncthreads(); 
    if (tx>0 && tx<MINMAX_W+1 && xpos<=maxx) {
      if (d21<d_Threshold[1]) {
	float minv = fminf(fminf(fminf(ymin2[tx-1], ymin2[tx+1]), ymin1[tx]), ymin3[tx]);
	minv = fminf(fminf(minv, d20), d22);
	if (d21<minv) { 
	  int pos = atomicInc(&cnt, 31);
	  points[3*pos+0] = xpos - 1;
	  points[3*pos+1] = ypos;
	  points[3*pos+2] = scale;
	}
      } 
      if (d21>d_Threshold[0]) {
	float maxv = fmaxf(fmaxf(fmaxf(ymax2[tx-1], ymax2[tx+1]), ymax1[tx]), ymax3[tx]);
	maxv = fmaxf(fmaxf(maxv, d20), d22);
	if (d21>maxv) { 
	  int pos = atomicInc(&cnt, 31);
	  points[3*pos+0] = xpos - 1;
	  points[3*pos+1] = ypos;
	  points[3*pos+2] = scale;
	}
      }
    }
    __syncthreads();
  }
  if (tx<cnt) {
    int xpos = points[3*tx+0];
    int ypos = points[3*tx+1];
    int scale = points[3*tx+2];
    int ptr = xpos + (ypos + (scale+1)*height)*pitch;
    float val = d_Data0[ptr];
    float *data1 = &d_Data0[ptr];
    float dxx = 2.0f*val - data1[-1] - data1[1];
    float dyy = 2.0f*val - data1[-pitch] - data1[pitch];
    float dxy = 0.25f*(data1[+pitch+1] + data1[-pitch-1] - data1[-pitch+1] - data1[+pitch-1]);
    float tra = dxx + dyy;
    float det = dxx*dyy - dxy*dxy;
    if (tra*tra<d_EdgeLimit*det) {
      float edge = __fdividef(tra*tra, det);
      float dx = 0.5f*(data1[1] - data1[-1]);
      float dy = 0.5f*(data1[pitch] - data1[-pitch]); 
      float *data0 = d_Data0 + ptr - height*pitch;
      float *data2 = d_Data0 + ptr + height*pitch;
      float ds = 0.5f*(data0[0] - data2[0]); 
      float dss = 2.0f*val - data2[0] - data0[0];
      float dxs = 0.25f*(data2[1] + data0[-1] - data0[1] - data2[-1]);
      float dys = 0.25f*(data2[pitch] + data0[-pitch] - data2[-pitch] - data0[pitch]);
      float idxx = dyy*dss - dys*dys;
      float idxy = dys*dxs - dxy*dss;   
      float idxs = dxy*dys - dyy*dxs;
      float idet = __fdividef(1.0f, idxx*dxx + idxy*dxy + idxs*dxs);
      float idyy = dxx*dss - dxs*dxs;
      float idys = dxy*dxs - dxx*dys;
      float idss = dxx*dyy - dxy*dxy;
      float pdx = idet*(idxx*dx + idxy*dy + idxs*ds);
      float pdy = idet*(idxy*dx + idyy*dy + idys*ds);
      float pds = idet*(idxs*dx + idys*dy + idss*ds);
      if (pdx<-0.5f || pdx>0.5f || pdy<-0.5f || pdy>0.5f || pds<-0.5f || pds>0.5f) {
	pdx = __fdividef(dx, dxx);
	pdy = __fdividef(dy, dyy);
	pds = __fdividef(ds, dss);
      }
      float dval = 0.5f*(dx*pdx + dy*pdy + ds*pds);
      int maxPts = d_MaxNumPoints;
      float sc = d_Scales[scale] * exp2f(pds*d_Factor);
      if (sc>=lowestScale) {
	unsigned int idx = atomicInc(d_PointCounter, 0x7fffffff);
	idx = (idx>=maxPts ? maxPts-1 : idx);
	d_Sift[idx].xpos = xpos + pdx;
	d_Sift[idx].ypos = ypos + pdy;
	d_Sift[idx].scale = sc;
	d_Sift[idx].sharpness = val + dval;
	d_Sift[idx].edgeness = edge;
	d_Sift[idx].subsampling = subsampling;
      }
    }
  }
}

__global__ void myFindPointsMulti_first(float *d_Data0, SiftPoint *d_Sift, int width, int pitch, int height, int nScales, float subsampling, float lowestScale)
{
  #define MEMWID (MINMAX_W + 2)
  __shared__ float ymin1[MEMWID], ymin2[MEMWID], ymin3[MEMWID];
  __shared__ float ymax1[MEMWID], ymax2[MEMWID], ymax3[MEMWID];
  __shared__ unsigned int cnt;
  __shared__ unsigned short points[96];

  int tx = threadIdx.x;
  int block = blockIdx.x/nScales;  //flatting the blocks
  int scale = blockIdx.x - nScales*block;  //blockIdx.x % nScales
  int minx = block*MINMAX_W;  //start point of an image of each block
  int maxx = min(minx + MINMAX_W, width); //end point of an image of each block
  int xpos = minx + tx;  //point of each thread

  int size = pitch*height;  //resize the image

  int ptr = size*scale + max(min(xpos-1, width-1), 0);  //point of each thread in DOG image
  
  if (tx==0)
    cnt = 0; 
  __syncthreads();
  float d10,d11,d12,d20,d21,d22,d30,d31,d32;
  int ypos = MINMAX_H*blockIdx.y ;
  int yptr0 = ptr + max(0,ypos-1)*pitch;
  int yptr1 = ptr + ypos*pitch;
  int yptr2 = ptr + min(height-1,ypos+1)*pitch;
  d10 = d_Data0[yptr0];
  d11 = d_Data0[yptr1];
  d30 = d_Data0[yptr0 + 2*size];
  d31 = d_Data0[yptr1 + 2*size];
  d20 = d_Data0[yptr0 + 1*size];
  d21 = d_Data0[yptr1 + 1*size];
  
  int yloops = min(height - MINMAX_H*blockIdx.y, MINMAX_H);
  for (int y=0;y<yloops;y++) {

    {
      d12 = d_Data0[yptr2];
      ymin1[tx] = fminf(fminf(d10, d11), d12);
      ymax1[tx] = fmaxf(fmaxf(d10, d11), d12);
    }
    {
      
      d32 = d_Data0[yptr2 + 2*size]; 
      ymin3[tx] = fminf(fminf(d30, d31), d32);
      ymax3[tx] = fmaxf(fmaxf(d30, d31), d32);
    }
    
    d22 = d_Data0[yptr2 + 1*size];
    ymin2[tx] = fminf(fminf(ymin1[tx], fminf(fminf(d20, d21), d22)), ymin3[tx]);
    ymax2[tx] = fmaxf(fmaxf(ymax1[tx], fmaxf(fmaxf(d20, d21), d22)), ymax3[tx]);
    __syncthreads(); 
    if (tx>0 && tx<MINMAX_W+1 && xpos<=maxx) {
      if (d21<d_Threshold[1]) {
  float minv = fminf(fminf(fminf(ymin2[tx-1], ymin2[tx+1]), ymin1[tx]), ymin3[tx]);
  minv = fminf(fminf(minv, d20), d22);
  if (d21<minv) { 
    int pos = atomicInc(&cnt, 31);
    points[3*pos+0] = xpos - 1;
    points[3*pos+1] = ypos;
    points[3*pos+2] = scale;
  }
      } 
      if (d21>d_Threshold[0]) {
  float maxv = fmaxf(fmaxf(fmaxf(ymax2[tx-1], ymax2[tx+1]), ymax1[tx]), ymax3[tx]);
  maxv = fmaxf(fmaxf(maxv, d20), d22);
  if (d21>maxv) { 
    int pos = atomicInc(&cnt, 31);
    points[3*pos+0] = xpos - 1;
    points[3*pos+1] = ypos;
    points[3*pos+2] = scale;
  }
      }
    }
    d10 = d11;
    d11 = d12;
    d20 = d21;
    d21 = d22;
    d30 = d31;
    d31 = d32;
    ypos = MINMAX_H*blockIdx.y +y +1 ;
    yptr2 = ptr + min(height-1,ypos+1)*pitch;
    __syncthreads();
  }
  if (tx<cnt) {
    int xpos = points[3*tx+0];
    int ypos = points[3*tx+1];
    int scale = points[3*tx+2];
    int ptr = xpos + (ypos + (scale+1)*height)*pitch;
    float val = d_Data0[ptr];
    float *data1 = &d_Data0[ptr];
    float dxx = 2.0f*val - data1[-1] - data1[1];
    float dyy = 2.0f*val - data1[-pitch] - data1[pitch];
    float dxy = 0.25f*(data1[+pitch+1] + data1[-pitch-1] - data1[-pitch+1] - data1[+pitch-1]);
    float tra = dxx + dyy;
    float det = dxx*dyy - dxy*dxy;
    if (tra*tra<d_EdgeLimit*det) {
      float edge = __fdividef(tra*tra, det);
      float dx = 0.5f*(data1[1] - data1[-1]);
      float dy = 0.5f*(data1[pitch] - data1[-pitch]); 
      float *data0 = d_Data0 + ptr - height*pitch;
      float *data2 = d_Data0 + ptr + height*pitch;
      float ds = 0.5f*(data0[0] - data2[0]); 
      float dss = 2.0f*val - data2[0] - data0[0];
      float dxs = 0.25f*(data2[1] + data0[-1] - data0[1] - data2[-1]);
      float dys = 0.25f*(data2[pitch] + data0[-pitch] - data2[-pitch] - data0[pitch]);
      float idxx = dyy*dss - dys*dys;
      float idxy = dys*dxs - dxy*dss;   
      float idxs = dxy*dys - dyy*dxs;
      float idet = __fdividef(1.0f, idxx*dxx + idxy*dxy + idxs*dxs);
      float idyy = dxx*dss - dxs*dxs;
      float idys = dxy*dxs - dxx*dys;
      float idss = dxx*dyy - dxy*dxy;
      float pdx = idet*(idxx*dx + idxy*dy + idxs*ds);
      float pdy = idet*(idxy*dx + idyy*dy + idys*ds);
      float pds = idet*(idxs*dx + idys*dy + idss*ds);
      if (pdx<-0.5f || pdx>0.5f || pdy<-0.5f || pdy>0.5f || pds<-0.5f || pds>0.5f) {
  pdx = __fdividef(dx, dxx);
  pdy = __fdividef(dy, dyy);
  pds = __fdividef(ds, dss);
      }
      float dval = 0.5f*(dx*pdx + dy*pdy + ds*pds);
      int maxPts = d_MaxNumPoints;
      float sc = d_Scales[scale] * exp2f(pds*d_Factor);
      if (sc>=lowestScale) {
  unsigned int idx = atomicInc(d_PointCounter, 0x7fffffff);
  idx = (idx>=maxPts ? maxPts-1 : idx);
  d_Sift[idx].xpos = xpos + pdx;
  d_Sift[idx].ypos = ypos + pdy;
  d_Sift[idx].scale = sc;
  d_Sift[idx].sharpness = val + dval;
  d_Sift[idx].edgeness = edge;
  d_Sift[idx].subsampling = subsampling;
      }
    }
  }
}

__global__ void myFindPointsMulti_second(float *d_Data0, SiftPoint *d_Sift, int width, int pitch, int height, int nScales, float subsampling, float lowestScale)
{
  #define MEMWID (MINMAX_W + 2)
  __shared__ float ymin2[MEMWID];//the min and max for 9 elements, shared in the xy plane
  __shared__ float ymax2[MEMWID];//only used when determine if key point or not, used per iteration, update per iteration
  float ymin[3*4];//the min and max for every 3 elements in 3 layers in the four inner loop(3*4*num of threads), shared by the z direction
  float ymax[3*4];//used by new iteration in the outer loop, update when starting a new iteration in outer loop
  float d[12];
  __shared__ unsigned int cnt;
  __shared__ unsigned short points[96*5];

  int reg_start = 0;
  int d2_start = 0;
  int d3_start = 6 - d2_start;

  int tx = threadIdx.x; //
 // int block = blockIdx.x/nScales;  //flatting the blocks
 // int scale = blockIdx.x - nScales*block;  //blockIdx.x % nScales
 // int minx = block*MINMAX_W;  //start point of an image of each block
  int minx = blockIdx.x * MINMAX_W;
  int maxx = min(minx + MINMAX_W, width); //end point of an image of each block
  int xpos = minx + tx;  //point of each thread 
  int size = pitch*height;  //resize the image 
  //Before the for loop, we need load the 0 and 1 elements
  //In the inner loop, we need to load 3 element(1 per layer) per thread in the y direction, and calculate the corresponding max and min stored in shared memory
  //In one iteration of inner loop,  
  //the ptr should be in the for loop
  if (tx==0)
    cnt = 0; 
  __syncthreads();
  int ptr = size*0 + max(min(xpos-1, width-1), 0); //thread position(among layers)
  int ypos = MINMAX_H*blockIdx.y; //for the first iteration in the y direction
  int yptr0 = ptr + max(0,ypos-1)*pitch;
  int yptr1 = ptr + ypos*pitch;
  int yptr2 = ptr + min(height-1,ypos+1)*pitch;
  float d10 = d_Data0[yptr0];
  float d11 = d_Data0[yptr1];
  float d20 = d_Data0[yptr0 + 1*size];
  float d21 = d_Data0[yptr1 + 1*size];
  float d30 = d_Data0[yptr0 + 2*size];
  float d31 = d_Data0[yptr1 + 2*size];
  d[0] = d30;
  d[1] = d31;
  int yloops = min(height - MINMAX_H*blockIdx.y, MINMAX_H); //number of inner loop
  //go into loop
  for(int scale = 0; scale <5; scale ++){
    for(int y = 0; y < yloops; y++){
      //In the first interation, need to load 2 elements for 3 layers
      //Else, only need to load 2 element for one new layer, and reuse the max and min value stored in the register array
      if(scale == 0){
        float d12 = d_Data0[yptr2];
        float d22 = d_Data0[yptr2 + 1*size];
        float d32 = d_Data0[yptr2 + 2*size];      
        ymin[y] = fminf(fminf(d10, d11), d12);
        ymax[y] = fmaxf(fmaxf(d10, d11), d12);
        ymin[y + 4] = fminf(fminf(d20, d21), d22); //y+4 is the start of second layer
        ymax[y + 4] = fmaxf(fmaxf(d20, d21), d22);
        ymin[y + 8] = fminf(fminf(d30, d31), d32);// y+8 is the start of third layer
        ymax[y + 8] = fmaxf(fmaxf(d30, d31), d32);
        ymin2[tx] = fminf(fminf(ymin[y], ymin[y + 4]), ymin[y + 8]); //this goes to shared memory
        ymax2[tx] = fmaxf(fmaxf(ymax[y], ymax[y + 4]), ymax[y + 8]);
        __syncthreads();
        //Wait till all the threads finish storing shared memory, now start determining process 
        if (tx>0 && tx<MINMAX_W+1 && xpos<=maxx){
          if (d21<d_Threshold[1]){
            float minv = fminf(fminf(fminf(ymin2[tx-1], ymin2[tx+1]), ymin[y]), ymin[y + 8]);
            minv = fminf(fminf(minv, d20), d22);
            if (d21<minv) { 
              int pos = atomicInc(&cnt, 155);
              points[3*pos+0] = xpos - 1;
              points[3*pos+1] = ypos;
              points[3*pos+2] = scale;
            }
          }
          if(d21>d_Threshold[0]){
            float maxv = fmaxf(fmaxf(fmaxf(ymax2[tx-1], ymax2[tx+1]), ymax[y]), ymax[y + 8]);
            maxv = fmaxf(fmaxf(maxv, d20), d22);
            if(d21>maxv){
              int pos = atomicInc(&cnt, 155);
              points[3*pos+0] = xpos - 1;
              points[3*pos+1] = ypos;
              points[3*pos+2] = scale;
            }
          }
        }
        //finish determining, now move register, update yptr2, prepare for the next inner interation
        d10 = d11;
        d11 = d12;
        d20 = d21;
        d21 = d22;
        d30 = d31;
        d31 = d32;
        ypos = MINMAX_H*blockIdx.y+y+1;
        yptr2 = ptr + min(height-1,ypos+1)*pitch;
        d[y+2] = d32;
      } 
      else{
        float d32 = d_Data0[yptr2 + 2*size]; 
        ymin[y + reg_start] = fminf(fminf(d30, d31), d32);
        ymax[y + reg_start] = fmaxf(fmaxf(d30, d31), d32);
        ymin2[tx] = fminf(fminf(ymin[y], ymin[y + 4]), ymin[y + 8]);
        ymax2[tx] = fmaxf(fmaxf(ymax[y], ymax[y + 4]), ymax[y + 8]);
        __syncthreads();
        if (tx>0 && tx<MINMAX_W+1 && xpos<=maxx){
          if (d[d2_start + 1 + y] < d_Threshold[1]){
            float minv = fminf(fminf(fminf(ymin2[tx-1], ymin2[tx+1]), ymin[y + reg_start]), ymin[y + (reg_start + 4)%12]);
            minv = fminf(fminf(minv, d[y+d2_start]), d[y+2+d2_start]);
            if (d[1+y+d2_start]<minv) { 
              int pos = atomicInc(&cnt, 155);
              points[3*pos+0] = xpos - 1;
              points[3*pos+1] = ypos;
              points[3*pos+2] = scale;
            }
          }
          if(d[1+y +d2_start]>d_Threshold[0]){
            float maxv = fmaxf(fmaxf(fmaxf(ymax2[tx-1], ymax2[tx+1]), ymax[y + reg_start]), ymax[y + (reg_start + 4)%12]);
            maxv = fmaxf(fmaxf(maxv, d[y+d2_start]), d[y+2+d2_start]);
            if(d[1+y+d2_start]>maxv){
              int pos = atomicInc(&cnt, 155);
              points[3*pos+0] = xpos - 1;
              points[3*pos+1] = ypos;
              points[3*pos+2] = scale;
            }
          }
        }
        d30 = d31;
        d31 = d32;
        ypos = MINMAX_H*blockIdx.y+y+1;
        yptr2 = ptr + min(height-1,ypos+1)*pitch;
        d[y+2+d3_start] = d32;
      }
    }
    //after the inner loop, load d30 and d31 of the new layer, update ptr
    ptr = size*(scale+1) + max(min(xpos-1, width-1), 0);
    ypos = MINMAX_H*blockIdx.y; //for the first iteration in the y direction
    yptr0 = ptr + max(0,ypos-1)*pitch;
    yptr1 = ptr + ypos*pitch;
    yptr2 = ptr + min(height-1,ypos+1)*pitch;
    d30 = d_Data0[yptr0 + 2*size];
    d31 = d_Data0[yptr1 + 2*size];
    reg_start = ((scale + 1)%3 - 1); // reg_start is the start position of 12 elements array, either 0,4, or 8
    if(reg_start == (-1)) reg_start = 2;
    reg_start *= 4;
    d3_start = (scale + 1)%2;
    d3_start *= 6;
    d2_start = 6 - d3_start;
    d[d3_start + 0] = d30;
    d[d3_start + 1] = d31;
__syncthreads();
  }
  //__syncthreads();
  for(tx = tx; tx < cnt; tx += MINMAX_W+2 ){
  
    int xpos = points[3*tx+0];
    int ypos = points[3*tx+1];
    int scale = points[3*tx+2];
    int ptr = xpos + (ypos + (scale+1)*height)*pitch;
    float val = d_Data0[ptr];
    float *data1 = &d_Data0[ptr];
    float dxx = 2.0f*val - data1[-1] - data1[1];
    float dyy = 2.0f*val - data1[-pitch] - data1[pitch];
    float dxy = 0.25f*(data1[+pitch+1] + data1[-pitch-1] - data1[-pitch+1] - data1[+pitch-1]);
    float tra = dxx + dyy;
    float det = dxx*dyy - dxy*dxy;
    if (tra*tra<d_EdgeLimit*det) {
      float edge = __fdividef(tra*tra, det);
      float dx = 0.5f*(data1[1] - data1[-1]);
      float dy = 0.5f*(data1[pitch] - data1[-pitch]); 
      float *data0 = d_Data0 + ptr - height*pitch;
      float *data2 = d_Data0 + ptr + height*pitch;
      float ds = 0.5f*(data0[0] - data2[0]); 
      float dss = 2.0f*val - data2[0] - data0[0];
      float dxs = 0.25f*(data2[1] + data0[-1] - data0[1] - data2[-1]);
      float dys = 0.25f*(data2[pitch] + data0[-pitch] - data2[-pitch] - data0[pitch]);
      float idxx = dyy*dss - dys*dys;
      float idxy = dys*dxs - dxy*dss;   
      float idxs = dxy*dys - dyy*dxs;
      float idet = __fdividef(1.0f, idxx*dxx + idxy*dxy + idxs*dxs);
      float idyy = dxx*dss - dxs*dxs;
      float idys = dxy*dxs - dxx*dys;
      float idss = dxx*dyy - dxy*dxy;
      float pdx = idet*(idxx*dx + idxy*dy + idxs*ds);
      float pdy = idet*(idxy*dx + idyy*dy + idys*ds);
      float pds = idet*(idxs*dx + idys*dy + idss*ds);
      if (pdx<-0.5f || pdx>0.5f || pdy<-0.5f || pdy>0.5f || pds<-0.5f || pds>0.5f) {
  pdx = __fdividef(dx, dxx);
  pdy = __fdividef(dy, dyy);
  pds = __fdividef(ds, dss);
      }
      float dval = 0.5f*(dx*pdx + dy*pdy + ds*pds);
      int maxPts = d_MaxNumPoints;
      float sc = d_Scales[scale] * exp2f(pds*d_Factor);
      if (sc>=lowestScale) {
  unsigned int idx = atomicInc(d_PointCounter, 0x7fffffff);
  idx = (idx>=maxPts ? maxPts-1 : idx);
  d_Sift[idx].xpos = xpos + pdx;
  d_Sift[idx].ypos = ypos  + pdy;
  d_Sift[idx].scale = sc;
  d_Sift[idx].sharpness = val + dval;
  d_Sift[idx].edgeness = edge;
  d_Sift[idx].subsampling = subsampling;
      }
    }
  }
}

__global__ void myFindPointsMulti_third(float *d_Data0, SiftPoint *d_Sift, int width, int pitch, int height, int nScales, float subsampling, float lowestScale)
{
  #define MEMWID (MINMAX_W + 2)
  __shared__ float ymin_9[MEMWID*4];//the min and max for 9 elements, shared in the xy plane
  __shared__ float ymax_9[MEMWID*4];//only used when determine if key point or not, used per iteration, update per iteration
 // float ymin[3*4];//the min and max for every 3 elements in 3 layers in the four inner loop(3*4*num of threads), shared by the z direction
 // float ymax[3*4];//used by new iteration in the outer loop, update when starting a new iteration in outer loop
 // float d[6];
  __shared__ unsigned int cnt;
  __shared__ unsigned short points[96*5];

  int tx = threadIdx.x; //
  int ty = threadIdx.y;
 // int block = blockIdx.x/nScales;  //flatting the blocks
 // int scale = blockIdx.x - nScales*block;  //blockIdx.x % nScales
 // int minx = block*MINMAX_W;  //start point of an image of each block
  int minx = blockIdx.x * MINMAX_W;
  int maxx = min(minx + MINMAX_W, width); //end point of an image of each block
  int xpos = minx + tx;  //point of each thread 
  int size = pitch*height;  //resize the image 
  //Before the for loop, we need load the 0 and 1 elements
  //In the inner loop, we need to load 3 element(1 per layer) per thread in the y direction, and calculate the corresponding max and min stored in shared memory
  //In one iteration of inner loop,  
  //the ptr should be in  the for loop
  if (tx==0)
    cnt = 0; 
  __syncthreads();
  int yloops = min(height - MINMAX_H*blockIdx.y, MINMAX_H); //number of elements in y direction
 // if(ty<yloops){
    int ptr = size*0 + max(min(xpos-1, width-1), 0); //thread position(among layers)
    int ypos = MINMAX_H * blockIdx.y + ty; //for the first iteration in the y direction
    int yptr0 = ptr + max(0,ypos-1)*pitch;
    int yptr1 = ptr + ypos*pitch;
    int yptr2 = ptr + min(height-1,ypos+1)*pitch;
    float d10 = d_Data0[yptr0];
    float d11 = d_Data0[yptr1];
    float d20 = d_Data0[yptr0 + 1*size];
    float d21 = d_Data0[yptr1 + 1*size];
    float d30 = d_Data0[yptr0 + 2*size];
    float d31 = d_Data0[yptr1 + 2*size];
    float d12, d22, d32, ymin1,ymin2, ymin3, ymax1, ymax2, ymax3;
    for(int scale = 0; scale < 5; scale ++){
      if(scale == 0){
        
        float d12 = d_Data0[yptr2];
          float d22 = d_Data0[yptr2 + 1*size];
          float d32 = d_Data0[yptr2 + 2*size];
          float ymin1 = fminf(fminf(d10, d11), d12);
          float ymax1 = fmaxf(fmaxf(d10, d11), d12);
          float ymin2 = fminf(fminf(d20, d21), d22); //y+4 is the start of second layer
          float ymax2 = fmaxf(fmaxf(d20, d21), d22);
          float ymin3 = fminf(fminf(d30, d31), d32);// y+8 is the start of third layer
          float ymax3 = fmaxf(fmaxf(d30, d31), d32);
          ymin_9[ty * MEMWID + tx] = fminf(fminf(ymin1, ymin2), ymin3); //this goes to shared memory
          ymax_9[ty * MEMWID + tx] = fmaxf(fmaxf(ymax1, ymax2), ymax3);
        
          __syncthreads();
        //  if(ty<yloops){
          
          if (tx>0 && tx<MINMAX_W+1 && xpos<=maxx){
            if (d21<d_Threshold[1]){
                float minv = fminf(fminf(fminf(ymin_9[tx-1 + ty * MEMWID], ymin_9[tx+1 + ty * MEMWID]), ymin1), ymin3);
                minv = fminf(fminf(minv, d20), d22);
                if (d21<minv) {
                    int pos = atomicInc(&cnt, 155);
                    points[3*pos+0] = xpos - 1;
                    points[3*pos+1] = ypos;
                    points[3*pos+2] = scale;
                }
              }
              if(d21>d_Threshold[0]){
                float maxv = fmaxf(fmaxf(fmaxf(ymax_9[tx-1 + ty * MEMWID], ymax_9[tx+1 + ty * MEMWID]), ymax1), ymax3);
                maxv = fmaxf(fmaxf(maxv, d20), d22);
                if(d21>maxv){
                    int pos = atomicInc(&cnt, 155);
                    points[3*pos+0] = xpos - 1;
                    points[3*pos+1] = ypos;
                    points[3*pos+2] = scale;
                }
              }
          }//}
            ymin1 = ymin2;
          ymin2 = ymin3;
          ymax1 = ymax2;
          ymax2 = ymax3;
          d20 = d30;
          d21 = d31;
          d22 = d32;
                
          }
      
      if(scale !=0){
        float d30 = d_Data0[yptr0 + 2*size];
        float d31 = d_Data0[yptr1 + 2*size];
        float d32 = d_Data0[yptr2 + 2*size];
        ymin3 = fminf(fminf(d30, d31), d32);// y+8 is the start of third layer
          ymax3 = fmaxf(fmaxf(d30, d31), d32);
          ymin_9[ty * MEMWID + tx] = fminf(fminf(ymin1, ymin2), ymin3); //this goes to shared memory
          ymax_9[ty * MEMWID + tx] = fmaxf(fmaxf(ymax1, ymax2), ymax3);
          __syncthreads();
          //if(ty<yloops){
      
          if (tx>0 && tx<MINMAX_W+1 && xpos<=maxx){
            if (d21<d_Threshold[1]){
                float minv = fminf(fminf(fminf(ymin_9[tx-1 + ty * MEMWID], ymin_9[tx+1 + ty * MEMWID]), ymin1), ymin3);
                minv = fminf(fminf(minv, d20), d22);
                if (d21<minv) {
                    int pos = atomicInc(&cnt, 155);
                    points[3*pos+0] = xpos - 1;
                    points[3*pos+1] = ypos;
                    points[3*pos+2] = scale;
                }
              }
              if(d21>d_Threshold[0]){
                float maxv = fmaxf(fmaxf(fmaxf(ymax_9[tx-1 + ty * MEMWID], ymax_9[tx+1 + ty * MEMWID]), ymax1), ymax3);
                maxv = fmaxf(fmaxf(maxv, d20), d22);
                if(d21>maxv){
                    int pos = atomicInc(&cnt, 155);
                    points[3*pos+0] = xpos - 1;
                    points[3*pos+1] = ypos;
                    points[3*pos+2] = scale;
                }
              }
          }//}
        
            ymin1 = ymin2;
          ymin2 = ymin3;
          ymax1 = ymax2;
          ymax2 = ymax3;
          d20 = d30;
          d21 = d31;
          d22 = d32;

      }
    
      
      ptr = size*(scale+1) + max(min(xpos-1, width-1), 0); //thread position(among layers)
      yptr0 = ptr + max(0,ypos-1)*pitch;
      yptr1 = ptr + ypos*pitch;
      yptr2 = ptr + min(height-1,ypos+1)*pitch;
      __syncthreads();
    }

  //}
 __syncthreads();
  tx = tx + ty * MEMWID;
  if(tx < cnt){
    int xpos = points[3*tx+0];
    int ypos = points[3*tx+1];
    int scale = points[3*tx+2];
    int ptr = xpos + (ypos + (scale+1)*height)*pitch;
    float val = d_Data0[ptr];
    float *data1 = &d_Data0[ptr];
    float dxx = 2.0f*val - data1[-1] - data1[1];
    float dyy = 2.0f*val - data1[-pitch] - data1[pitch];
    float dxy = 0.25f*(data1[+pitch+1] + data1[-pitch-1] - data1[-pitch+1] - data1[+pitch-1]);
    float tra = dxx + dyy;
    float det = dxx*dyy - dxy*dxy;
    if (tra*tra<d_EdgeLimit*det) {
      float edge = __fdividef(tra*tra, det);
      float dx = 0.5f*(data1[1] - data1[-1]);
      float dy = 0.5f*(data1[pitch] - data1[-pitch]); 
      float *data0 = d_Data0 + ptr - height*pitch;
      float *data2 = d_Data0 + ptr + height*pitch;
      float ds = 0.5f*(data0[0] - data2[0]); 
      float dss = 2.0f*val - data2[0] - data0[0];
      float dxs = 0.25f*(data2[1] + data0[-1] - data0[1] - data2[-1]);
      float dys = 0.25f*(data2[pitch] + data0[-pitch] - data2[-pitch] - data0[pitch]);
      float idxx = dyy*dss - dys*dys;
      float idxy = dys*dxs - dxy*dss;   
      float idxs = dxy*dys - dyy*dxs;
      float idet = __fdividef(1.0f, idxx*dxx + idxy*dxy + idxs*dxs);
      float idyy = dxx*dss - dxs*dxs;
      float idys = dxy*dxs - dxx*dys;
      float idss = dxx*dyy - dxy*dxy;
      float pdx = idet*(idxx*dx + idxy*dy + idxs*ds);
      float pdy = idet*(idxy*dx + idyy*dy + idys*ds);
      float pds = idet*(idxs*dx + idys*dy + idss*ds);
      if (pdx<-0.5f || pdx>0.5f || pdy<-0.5f || pdy>0.5f || pds<-0.5f || pds>0.5f) {
  pdx = __fdividef(dx, dxx);
  pdy = __fdividef(dy, dyy);
  pds = __fdividef(ds, dss);
      }
      float dval = 0.5f*(dx*pdx + dy*pdy + ds*pds);
      int maxPts = d_MaxNumPoints;
      float sc = d_Scales[scale] * exp2f(pds*d_Factor);
      if (sc>=lowestScale) {
  unsigned int idx = atomicInc(d_PointCounter, 0x7fffffff);
  idx = (idx>=maxPts ? maxPts-1 : idx);
  d_Sift[idx].xpos = xpos + pdx;
  d_Sift[idx].ypos = ypos + pdy ;
  d_Sift[idx].scale = sc;
  d_Sift[idx].sharpness = val + dval;
  d_Sift[idx].edgeness = edge;
  d_Sift[idx].subsampling = subsampling;
      }
    }
  }
}

__global__ void myLaplaceMultiMem_register_shuffle_findpoints(float *d_Image, SiftPoint *d_Sift , int width, int pitch, int height,int nScales, float subsampling, float lowestScale)
{
    //__shared__ float data1[(24 + 2*LAPLACE_R)*LAPLACE_S*4];
     __shared__ float data2[24*LAPLACE_S*6];
    __shared__ float data_share[14*(24+2*LAPLACE_R)];
    int tx = threadIdx.x;
    const int ty = threadIdx.y;
    int xp = blockIdx.x*22 + tx-1;
    int yp = blockIdx.y*4+ty-1;

    float *data = d_Image + max(min(xp - 4, width-1), 0);
    int h = height-1;
    int w = width - 1;
//    yp = max(0, min(yp, h));

    __shared__ float dog[24*6*7];
    __shared__ unsigned int cnt;
    __shared__ unsigned short points[96];

    if(tx == 0) cnt = 0;

    //because the size of block in y direction is 4, so each thread need to load three points
  /*  data_share[tx+(24+2*LAPLACE_R)*(ty)]=data[max(0, min(yp-4, h))*pitch];
    data_share[tx+(24+2*LAPLACE_R)*(ty+4)]=data[max(0, min(yp, h))*pitch];
    data_share[tx+(24+2*LAPLACE_R)*(ty+8)]=data[max(0, min(yp+4, h))*pitch]; */
    int yadd = yp-4;
    for(int i = ty; i < 14; i+= 6){
      data_share[tx+(24+2*LAPLACE_R)*(i)]=data[max(0, min(yadd, h))*pitch];
      yadd += 6;
    }

    __syncthreads();

    float reg0,reg1,reg2,reg3,reg4;
    reg0 = data_share[tx+(24+2*LAPLACE_R)*(ty+4)];
    reg1 = data_share[tx+(24+2*LAPLACE_R)*(ty+3)] + data_share[tx+(24+2*LAPLACE_R)*(ty+5)];
    reg2 = data_share[tx+(24+2*LAPLACE_R)*(ty+2)] + data_share[tx+(24+2*LAPLACE_R)*(ty+6)];
    reg3 = data_share[tx+(24+2*LAPLACE_R)*(ty+1)] + data_share[tx+(24+2*LAPLACE_R)*(ty+7)];
    reg4 = data_share[tx+(24+2*LAPLACE_R)*(ty)] + data_share[tx+(24+2*LAPLACE_R)*(ty+8)];


    //int the first 3 iteration, nso need to calculate the
    for(int scale =7;scale>=0;scale--){
    //const int scale = threadIdx.y;
    float *kernel = d_Kernel2 + scale*16;
    //float *sdata1 = data1 + (24 + 2*LAPLACE_R)*scale + ty*(24 + 2*LAPLACE_R)*LAPLACE_S;
    float mybuffer;

    //__syncthreads();

    mybuffer = kernel[4]*reg0 +
    kernel[3]*(reg1) +
    kernel[2]*(reg2) +
    kernel[1]*(reg3) +
    kernel[0]*(reg4);

    //__syncthreads();
    float buffer1 = __shfl(mybuffer, tx+1);
    float buffer2 = __shfl(mybuffer, tx+2);
    float buffer3 = __shfl(mybuffer, tx+3);
    float buffer4 = __shfl(mybuffer, tx+4);
    float buffer5 = __shfl(mybuffer, tx+5);
    float buffer6 = __shfl(mybuffer, tx+6);
    float buffer7 = __shfl(mybuffer, tx+7);
    float buffer8 = __shfl(mybuffer, tx+8);


    float *sdata2 = data2 + 24*scale + ty*24*LAPLACE_S;
    if (tx<24) {
        sdata2[tx] = kernel[4]*buffer4 +
            kernel[3]*(buffer3 + buffer5) + kernel[2]*(buffer2 +buffer6) +
            kernel[1]*(buffer1 + buffer7) + kernel[0]*(mybuffer + buffer8);

    }
    __syncthreads();
    if (tx<24 && scale<LAPLACE_S-1 && xp<width){
    yp = max(0, min(yp, h));
    xp = max(0, min(xp, w));
   //d_Result[scale*height*pitch + yp*pitch + xp] = sdata2[tx] - sdata2[tx+24];}
    dog[scale * 24 * 6 + ty*24 + tx] = sdata2[tx] - sdata2[tx+24];}
    __syncthreads();
    
  }
    //values for find points
    #define MEMWID (22 + 2)
    __shared__ float ymin_9[MEMWID*4];
    __shared__ float ymax_9[MEMWID*4];
    
    int minx = blockIdx.x * 22;
    int maxx = min(minx + 22,width);
    int xpos = minx + tx;
    int size = 24 * 6;
    int ypos = 4 * blockIdx.y + ty;
    if(tx<24 && ty < 4 && xpos < width && ypos < height ){
    int ptr = size * 0 + tx;
    int yptr0 = ptr + ty*24;
    int yptr1 = ptr + (ty + 1)*24;
    int yptr2 = ptr + (ty + 2)*24;
    float d10 = dog[yptr0];
    float d11 = dog[yptr1];
    float d20 = dog[yptr0 + 1*size];
    float d21 = dog[yptr1 + 1*size];
    float d30 = dog[yptr0 + 2*size];
    float d31 = dog[yptr1 + 2*size];
    float d12, d22, d32, ymin1,ymin2, ymin3, ymax1, ymax2, ymax3;
    for(int scale = 0; scale < 5; scale ++){
      if(scale == 0){

        float d12 = dog[yptr2];
          float d22 = dog[yptr2 + 1*size];
          float d32 = dog[yptr2 + 2*size];
          float ymin1 = fminf(fminf(d10, d11), d12);
          float ymax1 = fmaxf(fmaxf(d10, d11), d12);
          float ymin2 = fminf(fminf(d20, d21), d22); //y+4 is the start of second layer
          float ymax2 = fmaxf(fmaxf(d20, d21), d22);
          float ymin3 = fminf(fminf(d30, d31), d32);// y+8 is the start of third layer
          float ymax3 = fmaxf(fmaxf(d30, d31), d32);
          ymin_9[ty * MEMWID + tx] = fminf(fminf(ymin1, ymin2), ymin3); //this goes to shared memory
          ymax_9[ty * MEMWID + tx] = fmaxf(fmaxf(ymax1, ymax2), ymax3);

          __syncthreads();
        //  if(ty<yloops){

          if (tx>0 && tx<23 && xpos<=maxx){
            if (d21<d_Threshold[1]){
                float minv = fminf(fminf(fminf(ymin_9[tx-1 + ty * MEMWID], ymin_9[tx+1 + ty * MEMWID]), ymin1), ymin3);
                minv = fminf(fminf(minv, d20), d22);
                if (d21<minv) {
                    int pos = atomicInc(&cnt, 31);
                    points[3*pos+0] = xpos - 1;
                    points[3*pos+1] = ypos;
                    points[3*pos+2] = scale;
                }
              }
              if(d21>d_Threshold[0]){
                float maxv = fmaxf(fmaxf(fmaxf(ymax_9[tx-1 + ty * MEMWID], ymax_9[tx+1 + ty * MEMWID]), ymax1), ymax3);
                maxv = fmaxf(fmaxf(maxv, d20), d22);
                if(d21>maxv){
                    int pos = atomicInc(&cnt, 31);
                    points[3*pos+0] = xpos - 1;
                    points[3*pos+1] = ypos;
                    points[3*pos+2] = scale;
                }
              }
          }//}
            ymin1 = ymin2;
          ymin2 = ymin3;
          ymax1 = ymax2;
          ymax2 = ymax3;
          d20 = d30;
          d21 = d31;
          d22 = d32;

          }

      if(scale !=0){
        float d30 = dog[yptr0 + 2*size];
        float d31 = dog[yptr1 + 2*size];
        float d32 = dog[yptr2 + 2*size];
        ymin3 = fminf(fminf(d30, d31), d32);// y+8 is the start of third layer
          ymax3 = fmaxf(fmaxf(d30, d31), d32);
          ymin_9[ty * MEMWID + tx] = fminf(fminf(ymin1, ymin2), ymin3); //this goes to shared memory
          ymax_9[ty * MEMWID + tx] = fmaxf(fmaxf(ymax1, ymax2), ymax3);
          __syncthreads();
          //if(ty<yloops){

          if (tx>0 && tx<23 && xpos<=maxx){
            if (d21<d_Threshold[1]){
                float minv = fminf(fminf(fminf(ymin_9[tx-1 + ty * MEMWID], ymin_9[tx+1 + ty * MEMWID]), ymin1), ymin3);
                minv = fminf(fminf(minv, d20), d22);
                if (d21<minv) {
                    int pos = atomicInc(&cnt, 31);
                    points[3*pos+0] = xpos - 1;
                    points[3*pos+1] = ypos;
                    points[3*pos+2] = scale;
                }
              }
              if(d21>d_Threshold[0]){
                float maxv = fmaxf(fmaxf(fmaxf(ymax_9[tx-1 + ty * MEMWID], ymax_9[tx+1 + ty * MEMWID]), ymax1), ymax3);
                maxv = fmaxf(fmaxf(maxv, d20), d22);
                if(d21>maxv){
                    int pos = atomicInc(&cnt, 31);
                    points[3*pos+0] = xpos - 1;
                    points[3*pos+1] = ypos;
                    points[3*pos+2] = scale;
                }
              }
          }//}

            ymin1 = ymin2;
          ymin2 = ymin3;
          ymax1 = ymax2;
          ymax2 = ymax3;
          d20 = d30;
          d21 = d31;
          d22 = d32;

      }
       ptr = size * (scale+1) + tx;
      yptr0 = ptr + ty*24;
      yptr1 = ptr + (ty + 1)*24;
      yptr2 = ptr + (ty + 2)*24;


      __syncthreads();
    }}
    tx = tx + ty * 24;
if(tx < cnt){
  int xpos = points[3*tx+0];
  int ypos = points[3*tx+1];
  int scale = points[3*tx+2];
  int txshared = xpos-blockIdx.x*22+1;
  int tyshared = ypos - blockIdx.y * 4 + 1;
  //int ptr = xpos + (ypos + (scale+1)*height)*pitch;
  int ptr = (scale+1)*24 * 6 + tyshared * 24 + txshared;
  float val = dog[ptr];
  float *data1 = dog + ptr;
  float dxx = 2.0f*val - data1[-1] - data1[1];
  float dyy = 2.0f*val - data1[-24] - data1[24];
  float dxy = 0.25f*(data1[+24+1]);
  dxy += 0.25f * data1[-24-1];
  dxy += 0.25f* data1[-24+1];
  dxy += 0.25f * data1[+24-1];
  float tra = dxx + dyy;
  float det = dxx*dyy - dxy*dxy;
  if (tra*tra<d_EdgeLimit*det) {
    float edge = __fdividef(tra*tra, det);
    float dx = 0.5f*(data1[1] - data1[-1]);
    float dy = 0.5f*(data1[24] - data1[-24]);
    float *data0 = dog + ptr - 24*6;
    float *data2 = dog + ptr + 24*6;
    float ds = 0.5f*(data0[0] - data2[0]);
    float dss = 2.0f*val - data2[0] - data0[0];
    float dxs = 0.25f*(data2[1] + data0[-1] - data0[1] - data2[-1]);
    float dys = 0.25f*(data2[24] + data0[-24] - data2[-24] - data0[24]);
    float idxx = dyy*dss - dys*dys;
    float idxy = dys*dxs - dxy*dss;
    float idxs = dxy*dys - dyy*dxs;
    float idet = __fdividef(1.0f, idxx*dxx + idxy*dxy + idxs*dxs);
    float idyy = dxx*dss - dxs*dxs;
    float idys = dxy*dxs - dxx*dys;
    float idss = dxx*dyy - dxy*dxy;
    float pdx = idet*(idxx*dx + idxy*dy + idxs*ds);
    float pdy = idet*(idxy*dx + idyy*dy + idys*ds);
    float pds = idet*(idxs*dx + idys*dy + idss*ds);
    if (pdx<-0.5f || pdx>0.5f || pdy<-0.5f || pdy>0.5f || pds<-0.5f || pds>0.5f) {
pdx = __fdividef(dx, dxx);
pdy = __fdividef(dy, dyy);
pds = __fdividef(ds, dss);
    }
    float dval = 0.5f*(dx*pdx + dy*pdy + ds*pds);
    int maxPts = d_MaxNumPoints;
    float sc = d_Scales[scale] * exp2f(pds*d_Factor);
    if (sc>=lowestScale) {
unsigned int idx = atomicInc(d_PointCounter, 0x7fffffff);
idx = (idx>=maxPts ? maxPts-1 : idx);
d_Sift[idx].xpos = xpos + pdx;
d_Sift[idx].ypos = ypos + pdy ;
d_Sift[idx].scale = sc;
d_Sift[idx].sharpness = val + dval;
d_Sift[idx].edgeness = edge;
d_Sift[idx].subsampling = subsampling;
    }
  }
}

}
 __global__ void LaplaceMultiTex(cudaTextureObject_t texObj, float *d_Result, int width, int pitch, int height)
{
  __shared__ float data1[(LAPLACE_W + 2*LAPLACE_R)*LAPLACE_S];
  __shared__ float data2[LAPLACE_W*LAPLACE_S];
  const int tx = threadIdx.x;
  const int xp = blockIdx.x*LAPLACE_W + tx;
  const int yp = blockIdx.y;
  const int scale = threadIdx.y;
  float *kernel = d_Kernel2 + scale*16;
  float *sdata1 = data1 + (LAPLACE_W + 2*LAPLACE_R)*scale; 
  float x = xp-3.5;
  float y = yp+0.5;
  sdata1[tx] = kernel[4]*tex2D<float>(texObj, x, y) + 
    kernel[3]*(tex2D<float>(texObj, x, y-1.0) + tex2D<float>(texObj, x, y+1.0)) + 
    kernel[2]*(tex2D<float>(texObj, x, y-2.0) + tex2D<float>(texObj, x, y+2.0)) + 
    kernel[1]*(tex2D<float>(texObj, x, y-3.0) + tex2D<float>(texObj, x, y+3.0)) + 
    kernel[0]*(tex2D<float>(texObj, x, y-4.0) + tex2D<float>(texObj, x, y+4.0));
  __syncthreads();
  float *sdata2 = data2 + LAPLACE_W*scale; 
  if (tx<LAPLACE_W) {
    sdata2[tx] = kernel[4]*sdata1[tx+4] + 
      kernel[3]*(sdata1[tx+3] + sdata1[tx+5]) + 
      kernel[2]*(sdata1[tx+2] + sdata1[tx+6]) + 
      kernel[1]*(sdata1[tx+1] + sdata1[tx+7]) + 
      kernel[0]*(sdata1[tx+0] + sdata1[tx+8]);
  }
  __syncthreads(); 
  if (tx<LAPLACE_W && scale<LAPLACE_S-1 && xp<width) 
    d_Result[scale*height*pitch + yp*pitch + xp] = sdata2[tx] - sdata2[tx+LAPLACE_W];
}


 __global__ void LaplaceMultiMem(float *d_Image, float *d_Result, int width, int pitch, int height)
{
  __shared__ float data1[(LAPLACE_W + 2*LAPLACE_R)*LAPLACE_S];
  __shared__ float data2[LAPLACE_W*LAPLACE_S];
  const int tx = threadIdx.x;
  const int xp = blockIdx.x*LAPLACE_W + tx;
  const int yp = blockIdx.y;
  const int scale = threadIdx.y;


  float *kernel = d_Kernel2 + scale*16;
  float *sdata1 = data1 + (LAPLACE_W + 2*LAPLACE_R)*scale; 
  float *data = d_Image + max(min(xp - 4, width-1), 0);
  int h = height-1;


  sdata1[tx] = kernel[4]*data[min(yp, h)*pitch] +
    kernel[3]*(data[max(0, min(yp-1, h))*pitch] + data[min(yp+1, h)*pitch]) + 
    kernel[2]*(data[max(0, min(yp-2, h))*pitch] + data[min(yp+2, h)*pitch]) + 
    kernel[1]*(data[max(0, min(yp-3, h))*pitch] + data[min(yp+3, h)*pitch]) + 
    kernel[0]*(data[max(0, min(yp-4, h))*pitch] + data[min(yp+4, h)*pitch]);
  __syncthreads();
  float *sdata2 = data2 + LAPLACE_W*scale; 
  if (tx<LAPLACE_W) {
    sdata2[tx] = kernel[4]*sdata1[tx+4] + 
      kernel[3]*(sdata1[tx+3] + sdata1[tx+5]) + kernel[2]*(sdata1[tx+2] + sdata1[tx+6]) + 
      kernel[1]*(sdata1[tx+1] + sdata1[tx+7]) + kernel[0]*(sdata1[tx+0] + sdata1[tx+8]);
  }
  __syncthreads(); 
  if (tx<LAPLACE_W && scale<LAPLACE_S-1 && xp<width) 
    d_Result[scale*height*pitch + yp*pitch + xp] = sdata2[tx] - sdata2[tx+LAPLACE_W];
}


__global__ void myLaplaceMultiMem(float *d_Image, float *d_Result, int width, int pitch, int height)
{
    __shared__ float data1[(LAPLACE_W + 2*LAPLACE_R)*LAPLACE_S*4];
    __shared__ float data2[LAPLACE_W*LAPLACE_S*4];
    __shared__ float data_share[12*(LAPLACE_W+2*LAPLACE_R)];
    const int tx = threadIdx.x;
    const int ty = threadIdx.y;
    const int xp = blockIdx.x*LAPLACE_W + tx;
    const int yp = blockIdx.y*4+ty;
    float *data = d_Image + max(min(xp - 4, width-1), 0);
    int h = height-1;

    //float data_register [9];   //use register to locate data
    //for(int i=0;i<=8;i++){
      //  int tmp = i - 4;
       // data_register[i] = data[max(0, min(yp+tmp, h))*pitch];
    //}

    //because the size of block in y direction is 4, so each thread need to load three points
    data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty)]=data[max(0, min(yp-4, h))*pitch];
    data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty+4)]=data[max(0, min(yp, h))*pitch];
    data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty+8)]=data[max(0, min(yp+4, h))*pitch];

    __syncthreads();

    for(int scale =7;scale>=0;scale--){
        //const int scale = threadIdx.y;
        float *kernel = d_Kernel2 + scale*16;
        float *sdata1 = data1 + (LAPLACE_W + 2*LAPLACE_R)*scale + ty*(LAPLACE_W + 2*LAPLACE_R)*LAPLACE_S;

       /* sdata1[tx] = kernel[4]*data_register[4] +
            kernel[3]*(data_register[3] + data_register[5]) +
            kernel[2]*(data_register[2] + data_register[6]) +
            kernel[1]*(data_register[1] + data_register[7]) +
            kernel[0]*(data_register[0] + data_register[8]);*/

        //__syncthreads();

        sdata1[tx] = kernel[4]*data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty+4)] +
            kernel[3]*(data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty+3)] + data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty+5)]) +
            kernel[2]*(data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty+2)] + data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty+6)]) +
            kernel[1]*(data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty+1)] + data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty+7)]) +
            kernel[0]*(data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty)] + data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty+8)]);

        __syncthreads();

        float *sdata2 = data2 + LAPLACE_W*scale + ty*LAPLACE_W*LAPLACE_S;
        if (tx<LAPLACE_W) {
        sdata2[tx] = kernel[4]*sdata1[tx+4] +
        kernel[3]*(sdata1[tx+3] + sdata1[tx+5]) + kernel[2]*(sdata1[tx+2] + sdata1[tx+6]) +
        kernel[1]*(sdata1[tx+1] + sdata1[tx+7]) + kernel[0]*(sdata1[tx+0] + sdata1[tx+8]);

        }
        __syncthreads();
        if (tx<LAPLACE_W && scale<LAPLACE_S-1 && xp<width)
        d_Result[scale*height*pitch + yp*pitch + xp] = sdata2[tx] - sdata2[tx+LAPLACE_W];
        __syncthreads();
    }

}



__global__ void myLaplaceMultiMem_register(float *d_Image, float *d_Result, int width, int pitch, int height)
{
    __shared__ float data1[(LAPLACE_W + 2*LAPLACE_R)*LAPLACE_S*4];
    __shared__ float data2[LAPLACE_W*LAPLACE_S*4];
    __shared__ float data_share[12*(LAPLACE_W+2*LAPLACE_R)];
    const int tx = threadIdx.x;
    const int ty = threadIdx.y;
    const int xp = blockIdx.x*LAPLACE_W + tx;
    const int yp = blockIdx.y*4+ty;
    float *data = d_Image + max(min(xp - 4, width-1), 0);
    int h = height-1;


    //because the size of block in y direction is 4, so each thread need to load three points
    data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty)]=data[max(0, min(yp-4, h))*pitch];
    data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty+4)]=data[max(0, min(yp, h))*pitch];
    data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty+8)]=data[max(0, min(yp+4, h))*pitch];

    __syncthreads();

    float reg0,reg1,reg2,reg3,reg4;
    reg0 = data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty+4)];
    reg1 = data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty+3)] + data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty+5)];
    reg2 = data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty+2)] + data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty+6)];
    reg3 = data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty+1)] + data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty+7)];
    reg4 = data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty)] + data_share[tx+(LAPLACE_W+2*LAPLACE_R)*(ty+8)];



    for(int scale =7;scale>=0;scale--){
        //const int scale = threadIdx.y;
        float *kernel = d_Kernel2 + scale*16;
        float *sdata1 = data1 + (LAPLACE_W + 2*LAPLACE_R)*scale + ty*(LAPLACE_W + 2*LAPLACE_R)*LAPLACE_S;


        sdata1[tx] = kernel[4]*reg0 +
        kernel[3]*(reg1) +
        kernel[2]*(reg2) +
        kernel[1]*(reg3) +
        kernel[0]*(reg4);

        __syncthreads();

        float *sdata2 = data2 + LAPLACE_W*scale + ty*LAPLACE_W*LAPLACE_S;
        if (tx<LAPLACE_W) {
            sdata2[tx] = kernel[4]*sdata1[tx+4] +
                kernel[3]*(sdata1[tx+3] + sdata1[tx+5]) + kernel[2]*(sdata1[tx+2] + sdata1[tx+6]) +
                kernel[1]*(sdata1[tx+1] + sdata1[tx+7]) + kernel[0]*(sdata1[tx+0] + sdata1[tx+8]);

        }
        __syncthreads();
        if (tx<LAPLACE_W && scale<LAPLACE_S-1 && xp<width)
            d_Result[scale*height*pitch + yp*pitch + xp] = sdata2[tx] - sdata2[tx+LAPLACE_W];
        __syncthreads();
    }

}






__global__ void myLaplaceMultiMem_register_shuffle(float *d_Image, float *d_Result, int width, int pitch, int height)
{
    //__shared__ float data1[(24 + 2*LAPLACE_R)*LAPLACE_S*4];
    __shared__ float data2[24*LAPLACE_S*4];
    __shared__ float data_share[12*(24+2*LAPLACE_R)];
    const int tx = threadIdx.x;
    const int ty = threadIdx.y;
    const int xp = blockIdx.x*24 + tx;
    const int yp = blockIdx.y*4+ty;
    float *data = d_Image + max(min(xp - 4, width-1), 0);
    int h = height-1;

    //because the size of block in y direction is 4, so each thread need to load three points
    data_share[tx+(24+2*LAPLACE_R)*(ty)]=data[max(0, min(yp-4, h))*pitch];
    data_share[tx+(24+2*LAPLACE_R)*(ty+4)]=data[max(0, min(yp, h))*pitch];
    data_share[tx+(24+2*LAPLACE_R)*(ty+8)]=data[max(0, min(yp+4, h))*pitch];

    __syncthreads();

    float reg0,reg1,reg2,reg3,reg4;
    reg0 = data_share[tx+(24+2*LAPLACE_R)*(ty+4)];
    reg1 = data_share[tx+(24+2*LAPLACE_R)*(ty+3)] + data_share[tx+(24+2*LAPLACE_R)*(ty+5)];
    reg2 = data_share[tx+(24+2*LAPLACE_R)*(ty+2)] + data_share[tx+(24+2*LAPLACE_R)*(ty+6)];
    reg3 = data_share[tx+(24+2*LAPLACE_R)*(ty+1)] + data_share[tx+(24+2*LAPLACE_R)*(ty+7)];
    reg4 = data_share[tx+(24+2*LAPLACE_R)*(ty)] + data_share[tx+(24+2*LAPLACE_R)*(ty+8)];



    for(int scale =7;scale>=0;scale--){
    //const int scale = threadIdx.y;
    float *kernel = d_Kernel2 + scale*16;
    //float *sdata1 = data1 + (24 + 2*LAPLACE_R)*scale + ty*(24 + 2*LAPLACE_R)*LAPLACE_S;
    float mybuffer;

    //__syncthreads();

    mybuffer = kernel[4]*reg0 +
    kernel[3]*(reg1) +
    kernel[2]*(reg2) +
    kernel[1]*(reg3) +
    kernel[0]*(reg4);

    //__syncthreads();
    float buffer1 = __shfl(mybuffer, tx+1);
    float buffer2 = __shfl(mybuffer, tx+2);
    float buffer3 = __shfl(mybuffer, tx+3);
    float buffer4 = __shfl(mybuffer, tx+4);
    float buffer5 = __shfl(mybuffer, tx+5);
    float buffer6 = __shfl(mybuffer, tx+6);
    float buffer7 = __shfl(mybuffer, tx+7);
    float buffer8 = __shfl(mybuffer, tx+8);


    float *sdata2 = data2 + 24*scale + ty*24*LAPLACE_S;
    if (tx<24) {
        sdata2[tx] = kernel[4]*buffer4 +
            kernel[3]*(buffer3 + buffer5) + kernel[2]*(buffer2 +buffer6) +
            kernel[1]*(buffer1 + buffer7) + kernel[0]*(mybuffer + buffer8);

    }
    __syncthreads();
    if (tx<24 && scale<LAPLACE_S-1 && xp<width)
    d_Result[scale*height*pitch + yp*pitch + xp] = sdata2[tx] - sdata2[tx+24];
    __syncthreads();
    }

}

 __global__ void myLowPass(float *d_Image, float *d_Result, int width, int pitch, int height)
{
    __shared__ float buffer[(LOWPASS_W + 2*LOWPASS_R)*LOWPASS_H];
    __shared__ float data_share[LOWPASS_H*2*(LOWPASS_W+2*LOWPASS_R)];
    //float mybuffer;
    const int tx = threadIdx.x;
    const int ty = threadIdx.y;
    const int xp = blockIdx.x*LOWPASS_W + tx;
    const int yp = blockIdx.y*LOWPASS_H + ty;
    float *kernel = d_Kernel2;
    float *data = d_Image + max(min(xp - 4, width-1), 0);
    float *buff = buffer + ty*(LOWPASS_W + 2*LOWPASS_R);
    int h = height-1;

    //use shared memory to optimze the code, since shared memory is very fast

    data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+4)]=data[max(0, min(yp, h))*pitch];
    if(ty<4)
        data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+4-LOWPASS_H/2)]=data[max(0, min(yp-LOWPASS_H/2, h))*pitch];
    else
        data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+4+LOWPASS_H/2)]=data[max(0, min(yp+LOWPASS_H/2, h))*pitch];


    __syncthreads();

    if (yp<height)
        buff[tx] = kernel[4]*data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+4)] +
            kernel[3]*(data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+3)] + data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+5)]) +
            kernel[2]*(data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+2)] + data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+6)]) +
            kernel[1]*(data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+1)] + data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+7)]) +
            kernel[0]*(data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty)] + data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+8)]);
    __syncthreads();
    if (tx<LOWPASS_W && xp<width && yp<height) {
        d_Result[yp*pitch + xp] = kernel[4]*buff[tx+4] +
            kernel[3]*(buff[tx+3] + buff[tx+5]) + kernel[2]*(buff[tx+2] + buff[tx+6]) +
            kernel[1]*(buff[tx+1] + buff[tx+7]) + kernel[0]*(buff[tx+0] + buff[tx+8]);



    }
}

__global__ void myLowPass_shuffle(float *d_Image, float *d_Result, int width, int pitch, int height)
{
    //__shared__ float buffer[(LOWPASS_W + 2*LOWPASS_R)*LOWPASS_H];
    __shared__ float data_share[LOWPASS_H*2*(LOWPASS_W+2*LOWPASS_R)];
    float mybuffer;
    const int tx = threadIdx.x;
    const int ty = threadIdx.y;
    const int xp = blockIdx.x*LOWPASS_W + tx;
    const int yp = blockIdx.y*LOWPASS_H + ty;
    float *kernel = d_Kernel2;
    float *data = d_Image + max(min(xp - 4, width-1), 0);
    //float *buff = buffer + ty*(LOWPASS_W + 2*LOWPASS_R);
    int h = height-1;

    //use shared memory to optimze the code, since shared memory is very fast

    data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+4)]=data[max(0, min(yp, h))*pitch];
    if(ty<4)
        data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+4-LOWPASS_H/2)]=data[max(0, min(yp-LOWPASS_H/2, h))*pitch];
    else
        data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+4+LOWPASS_H/2)]=data[max(0, min(yp+LOWPASS_H/2, h))*pitch];


__syncthreads();

if (yp<height)
    mybuffer = kernel[4]*data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+4)] +
        kernel[3]*(data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+3)] + data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+5)]) +
        kernel[2]*(data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+2)] + data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+6)]) +
        kernel[1]*(data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+1)] + data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+7)]) +
        kernel[0]*(data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty)] + data_share[tx+(LOWPASS_W+2*LOWPASS_R)*(ty+8)]);
//__syncthreads();
        float buffer1 = __shfl(mybuffer, tx+1);
        float buffer2 = __shfl(mybuffer, tx+2);
        float buffer3 = __shfl(mybuffer, tx+3);
        float buffer4 = __shfl(mybuffer, tx+4);
        float buffer5 = __shfl(mybuffer, tx+5);
        float buffer6 = __shfl(mybuffer, tx+6);
        float buffer7 = __shfl(mybuffer, tx+7);
        float buffer8 = __shfl(mybuffer, tx+8);
        if (tx<LOWPASS_W && xp<width && yp<height) {
            d_Result[yp*pitch + xp] = kernel[4]*buffer4 +
            kernel[3]*(buffer3 + buffer5) + kernel[2]*(buffer2 + buffer6) +
            kernel[1]*(buffer1 + buffer7) + kernel[0]*(mybuffer + buffer8);


    }
}



__global__ void LowPass(float *d_Image, float *d_Result, int width, int pitch, int height)
{
    __shared__ float buffer[(LOWPASS_W + 2*LOWPASS_R)*LOWPASS_H];
    const int tx = threadIdx.x;
    const int ty = threadIdx.y;
    const int xp = blockIdx.x*LOWPASS_W + tx;
    const int yp = blockIdx.y*LOWPASS_H + ty;
    float *kernel = d_Kernel2;
    float *data = d_Image + max(min(xp - 4, width-1), 0);
    float *buff = buffer + ty*(LOWPASS_W + 2*LOWPASS_R);
    int h = height-1;
    if (yp<height)
        buff[tx] = kernel[4]*data[min(yp, h)*pitch] +
            kernel[3]*(data[max(0, min(yp-1, h))*pitch] + data[min(yp+1, h)*pitch]) +
            kernel[2]*(data[max(0, min(yp-2, h))*pitch] + data[min(yp+2, h)*pitch]) +
            kernel[1]*(data[max(0, min(yp-3, h))*pitch] + data[min(yp+3, h)*pitch]) +
            kernel[0]*(data[max(0, min(yp-4, h))*pitch] + data[min(yp+4, h)*pitch]);
    __syncthreads();
    if (tx<LOWPASS_W && xp<width && yp<height) {
        d_Result[yp*pitch + xp] = kernel[4]*buff[tx+4] +
            kernel[3]*(buff[tx+3] + buff[tx+5]) + kernel[2]*(buff[tx+2] + buff[tx+6]) +
            kernel[1]*(buff[tx+1] + buff[tx+7]) + kernel[0]*(buff[tx+0] + buff[tx+8]);
    }
}


