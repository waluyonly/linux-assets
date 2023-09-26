/* Copyright (C) 2015 Hans-Kristian Arntzen <maister@archlinux.us>
 *
 * Permission is hereby granted, free of charge,
 * to any person obtaining a copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation the rights to
 * use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software,
 * and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 * INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 * IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

// Radix 16 FFT is implemented by doing separate radix-4 FFTs in four threads, then the results are shared via shared memory,
// and the final radix-16 is completed by doing radix-4 FFT again.
// Radix-16 FFT can be implemented directly without shared memory,
// but the register pressure would likely degrade performance significantly over just using shared.

// The radix-16 FFT would normally looks like this:
// cfloat a[i] = load_global(.... + i * quarter_samples);
// However, we interleave these into 4 separate threads (using LocalInvocationID.z) so that every thread
// gets its own FFT-4 transform.

// Z == 0, (0, 4,  8, 12)
// Z == 1, (1, 5,  9, 13)
// Z == 2, (2, 6, 10, 14)
// Z == 3, (3, 7, 11, 15)

// The FFT results are written in stockham autosort fashion to shared memory.
// The final FFT-4 transform is then read from shared memory with the same interleaving pattern used above.

void FFT16_p1_horiz(uvec2 i)
{
    uint quarter_samples = gl_NumWorkGroups.x * gl_WorkGroupSize.x;
    uint offset = i.y * quarter_samples * 16u;

    uint fft = gl_LocalInvocationID.x;
    uint block = gl_LocalInvocationID.z;
    uint base = get_shared_base(fft);

#ifdef FFT_INPUT_TEXTURE
    cfloat a = load_texture(i + uvec2((block +  0u) * quarter_samples, 0u));
    cfloat b = load_texture(i + uvec2((block +  4u) * quarter_samples, 0u));
    cfloat c = load_texture(i + uvec2((block +  8u) * quarter_samples, 0u));
    cfloat d = load_texture(i + uvec2((block + 12u) * quarter_samples, 0u));
#else
    cfloat a = load_global(offset + i.x + (block +  0u) * quarter_samples);
    cfloat b = load_global(offset + i.x + (block +  4u) * quarter_samples);
    cfloat c = load_global(offset + i.x + (block +  8u) * quarter_samples);
    cfloat d = load_global(offset + i.x + (block + 12u) * quarter_samples);
#endif
    FFT4_p1(a, b, c, d);

    store_shared(a, b, c, d, block, base);
    load_shared(a, b, c, d, block, base);

    const uint p = 4u;
    FFT4(a, b, c, d, FFT_OUTPUT_STEP * block, p);

    uint k = (FFT_OUTPUT_STEP * block) & (p - 1u);
    uint j = ((FFT_OUTPUT_STEP * block - k) * 4u) + k;

#ifndef FFT_OUTPUT_IMAGE
    store_global(offset + 16u * i.x + ((j + 0u * p) >> FFT_OUTPUT_SHIFT), a);
    store_global(offset + 16u * i.x + ((j + 1u * p) >> FFT_OUTPUT_SHIFT), c);
    store_global(offset + 16u * i.x + ((j + 2u * p) >> FFT_OUTPUT_SHIFT), b);
    store_global(offset + 16u * i.x + ((j + 3u * p) >> FFT_OUTPUT_SHIFT), d);
#endif
}

void FFT16_horiz(uvec2 i, uint p)
{
    uint quarter_samples = gl_NumWorkGroups.x * gl_WorkGroupSize.x;
    uint offset = i.y * quarter_samples * 16u;

    uint fft = gl_LocalInvocationID.x;
    uint block = gl_LocalInvocationID.z;
    uint base = get_shared_base(fft);

    cfloat a = load_global(offset + i.x + (block +  0u) * quarter_samples);
    cfloat b = load_global(offset + i.x + (block +  4u) * quarter_samples);
    cfloat c = load_global(offset + i.x + (block +  8u) * quarter_samples);
    cfloat d = load_global(offset + i.x + (block + 12u) * quarter_samples);

    FFT4(a, b, c, d, FFT_OUTPUT_STEP * i.x, p);

    store_shared(a, b, c, d, block, base);
    load_shared(a, b, c, d, block, base);

    uint k = (FFT_OUTPUT_STEP * i.x) & (p - 1u);
    uint j = ((FFT_OUTPUT_STEP * i.x - k) * 16u) + k;

    FFT4(a, b, c, d, k + block * p, 4u * p);

#ifdef FFT_OUTPUT_IMAGE
    store(ivec2(j + (block +  0u) * p, i.y), a);
    store(ivec2(j + (block +  4u) * p, i.y), c);
    store(ivec2(j + (block +  8u) * p, i.y), b);
    store(ivec2(j + (block + 12u) * p, i.y), d);
#else
    store_global(offset + ((j + (block +  0u) * p) >> FFT_OUTPUT_SHIFT), a);
    store_global(offset + ((j + (block +  4u) * p) >> FFT_OUTPUT_SHIFT), c);
    store_global(offset + ((j + (block +  8u) * p) >> FFT_OUTPUT_SHIFT), b);
    store_global(offset + ((j + (block + 12u) * p) >> FFT_OUTPUT_SHIFT), d);
#endif
}

void FFT16_p1_vert(uvec2 i)
{
    uvec2 quarter_samples = gl_NumWorkGroups.xy * gl_WorkGroupSize.xy;
    uint stride = uStride;
    uint y_stride = stride * quarter_samples.y;
    uint offset = stride * i.y;

    uint fft = gl_LocalInvocationID.x;
    uint block = gl_LocalInvocationID.z;
    uint base = get_shared_base(fft);

#ifdef FFT_INPUT_TEXTURE
    cfloat a = load_texture(i + uvec2(0u, (block +  0u) * quarter_samples.y));
    cfloat b = load_texture(i + uvec2(0u, (block +  4u) * quarter_samples.y));
    cfloat c = load_texture(i + uvec2(0u, (block +  8u) * quarter_samples.y));
    cfloat d = load_texture(i + uvec2(0u, (block + 12u) * quarter_samples.y));
#else
    cfloat a = load_global(offset + i.x + (block +  0u) * y_stride);
    cfloat b = load_global(offset + i.x + (block +  4u) * y_stride);
    cfloat c = load_global(offset + i.x + (block +  8u) * y_stride);
    cfloat d = load_global(offset + i.x + (block + 12u) * y_stride);
#endif
    FFT4_p1(a, b, c, d);

    store_shared(a, b, c, d, block, base);
    load_shared(a, b, c, d, block, base);

    const uint p = 4u;
    FFT4(a, b, c, d, block, p);

#ifndef FFT_OUTPUT_IMAGE
    store_global((16u * i.y + block +  0u) * stride + i.x, a);
    store_global((16u * i.y + block +  4u) * stride + i.x, c);
    store_global((16u * i.y + block +  8u) * stride + i.x, b);
    store_global((16u * i.y + block + 12u) * stride + i.x, d);
#endif
}

void FFT16_vert(uvec2 i, uint p)
{
    uvec2 quarter_samples = gl_NumWorkGroups.xy * gl_WorkGroupSize.xy;
    uint stride = uStride;
    uint y_stride = stride * quarter_samples.y;
    uint offset = stride * i.y;

    uint fft = gl_LocalInvocationID.x;
    uint block = gl_LocalInvocationID.z;
    uint base = get_shared_base(fft);

    cfloat a = load_global(offset + i.x + (block +  0u) * y_stride);
    cfloat b = load_global(offset + i.x + (block +  4u) * y_stride);
    cfloat c = load_global(offset + i.x + (block +  8u) * y_stride);
    cfloat d = load_global(offset + i.x + (block + 12u) * y_stride);

    FFT4(a, b, c, d, i.y, p);

    store_shared(a, b, c, d, block, base);
    load_shared(a, b, c, d, block, base);

    uint k = i.y & (p - 1u);
    uint j = ((i.y - k) * 16u) + k;

    FFT4(a, b, c, d, k + block * p, 4u * p);

#ifdef FFT_OUTPUT_IMAGE
    store(ivec2(i.x, j + (block +  0u) * p), a);
    store(ivec2(i.x, j + (block +  4u) * p), c);
    store(ivec2(i.x, j + (block +  8u) * p), b);
    store(ivec2(i.x, j + (block + 12u) * p), d);
#else
    store_global(stride * (j + (block +  0u) * p) + i.x, a);
    store_global(stride * (j + (block +  4u) * p) + i.x, c);
    store_global(stride * (j + (block +  8u) * p) + i.x, b);
    store_global(stride * (j + (block + 12u) * p) + i.x, d);
#endif
}

