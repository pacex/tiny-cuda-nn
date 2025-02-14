/*
 * Copyright (c) 2020-2023, NVIDIA CORPORATION.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted
 * provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright notice, this list of
 *       conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright notice, this list of
 *       conditions and the following disclaimer in the documentation and/or other materials
 *       provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the names of its contributors may be used
 *       to endorse or promote products derived from this software without specific prior written
 *       permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
 * FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 * BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
 * OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TOR (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/** @file   neural_surface.cu
 *  @author Thomas Müller, NVIDIA (original tiny-cuda-nn author)
 *			Pascal Walloner, University of Gothenburg
 *  @brief  Sample application that uses the tiny cuda nn framework and a custom input encoding
 *			to map surface points on 3D meshes to their material properties.
 */

#include <tiny-cuda-nn/common_device.h>

#include <tiny-cuda-nn/config.h>

#include <stbi/stbi_wrapper.h>
#include <stbi/stb_image.h>
#include <stbi/stb_image_write.h>

#include <chrono>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <curand.h>
#include <curand_kernel.h>
#include <math.h>
#include <tiny-cuda-nn/encodings/vertex.h>
#include <tiny-cuda-nn/encoding.h>

#define TINYOBJLOADER_IMPLEMENTATION
#include "tiny_obj_loader.h"



using namespace tcnn;
using precision_t = network_precision_t;

struct Texture {
	bool valid;
	cudaTextureObject_t texture;
	int width;
	int height;
	cudaResourceDesc resDesc;
	cudaTextureDesc texDesc;
	GPUMemory<float> image;
};

struct Material {
	float diffuse[3];
	Texture map_Kd;
	Texture map_Bump;
};

struct EvalResult {
	float MSE;
	uint32_t n_floats;
	long EvalTime;
};


#define N_INPUT_DIMS 3

// Modify N_OUTPUT_DIMS to match the number of surface propertie channels that should be represented
#define N_OUTPUT_DIMS 6

GPUMemory<float> load_image(const std::string& filename, int& width, int& height) {
	// width * height * RGBA
	float* out = load_stbi(&width, &height, filename.c_str());

	GPUMemory<float> result(width * height * 4);
	result.copy_from_host(out);
	free(out); // release memory of image data

	return result;
}

template <typename T>
__global__ void to_ldr(const uint64_t num_elements, const uint32_t n_channels, const uint32_t stride, const uint32_t offset, const T* __restrict__ in, const float* mask, uint8_t* __restrict__ out) {
	const uint64_t i = threadIdx.x + blockIdx.x * blockDim.x;
	if (i >= num_elements) return;

	const uint64_t pixel = i / 4;
	const uint32_t channel = i - pixel * 4;

	if (mask[pixel * N_INPUT_DIMS + 1] < 0.0f || mask[pixel * N_INPUT_DIMS + 2] < 0.0f) {
		out[i] = (uint8_t)0;
		return;
	}
		
	if (channel < n_channels)
		out[i] = (uint8_t)(powf(fmaxf(fminf(in[pixel * stride + channel + offset], 1.0f), 0.0f), 1.0f / 2.2f) * 255.0f + 0.5f);
	else if (channel < 3)
		out[i] = (uint8_t)0;
	else 
		out[i] = (uint8_t)255;
}

template <typename T>
void save_image(const T* image, const float* mask, int width, int height, int n_channels, int channel_stride, int channel_offset, const std::string& filename) {

	std::cout << filename << "... " << std::endl;
	GPUMemory<uint8_t> image_ldr(width * height * 4);
	linear_kernel(to_ldr<T>, 0, nullptr, width * height * 4, n_channels, channel_stride, channel_offset, image, mask, image_ldr.data());

	std::vector<uint8_t> image_ldr_host(width * height * 4);
	CUDA_CHECK_THROW(cudaMemcpy(image_ldr_host.data(), image_ldr.data(), image_ldr.size(), cudaMemcpyDeviceToHost));

	//save_stbi(image_ldr_host.data(), width, height, n_channels, filename.c_str());
	if (stbi_write_png(filename.c_str(), width, height, 4, image_ldr_host.data(), width * sizeof(uint8_t) * 4) == 0) {
		throw std::runtime_error{ fmt::format("Failed to write image {}", filename.c_str()) };
	}
}

template <typename T>
void save_images(const T* data, const float* mask, int width, int height, const std::string& filename) {

	std::cout << "Writing image files... " << std::endl;
	for (int i = 0; i < N_OUTPUT_DIMS / 3; i++) {
		save_image(data, mask, width, height, 3, N_OUTPUT_DIMS, i * 3, fmt::format("images/ch{}_", i) + filename);
	}
	std::cout << "Done." << std::endl;
}

template <uint32_t stride>
__global__ void eval_image(uint32_t n_elements, cudaTextureObject_t texture, float* __restrict__ xs_and_ys, float* __restrict__ result) {
	uint32_t i = blockIdx.x * blockDim.x + threadIdx.x;
	if (i >= n_elements) return;

	uint32_t output_idx = i * stride;
	uint32_t input_idx = i * 2;

	float4 val = tex2D<float4>(texture, xs_and_ys[input_idx], xs_and_ys[input_idx+1]);
	result[output_idx + 0] = val.x;
	result[output_idx + 1] = val.y;
	result[output_idx + 2] = val.z;

	for (uint32_t i = 3; i < stride; ++i) {
		result[output_idx + i] = 1;
	}
}

// Generate training data

__global__ void setup_kernel(uint32_t n_elements, curandState* state) {

	int idx = threadIdx.x + blockDim.x * blockIdx.x + blockDim.y * blockDim.x * blockIdx.y;

	if (idx >= n_elements)
		return;

	curand_init(1337, idx, 0, &state[idx]);
}

template <typename T>
__global__ void generate_face_positions(uint32_t n_elements, uint32_t n_faces, curandState* crs, tinyobj::index_t* indices, float* vertices, float* cdf, float* result) {

	int idx = threadIdx.x + blockDim.x * blockIdx.x;

	if (idx >= n_elements)
		return;

	int output_idx = idx * 3;

	// Pick random face uniformly
	float r = fmodf(curand_uniform(&crs[idx]), 1.0f);

	// Weigh faces by their relative area using precomputed CDF - unused
	/*
	uint32_t faceId = n_faces - 1;

	for (uint32_t i = 0; i < n_faces; i++) {
		if (r < cdf[i]) {
			faceId = i;
			break;
		}
	}
	*/

	uint32_t faceId = (uint32_t)(r * n_faces);
	result[output_idx + 0] = *((float*) &faceId);

	// Sample Barycentric coordinates on picked face
	float r1, r2;
	r1 = curand_uniform(&crs[idx]);
	r2 = curand_uniform(&crs[idx]);

	result[output_idx + 1] = 1.0f - sqrt(r1);
	result[output_idx + 2] = sqrt(r1) * (1.0f - r2);
}

__global__ void rescale_faceIds(uint32_t n_elements, uint32_t n_faces, float* training_batch, float* result) {

	int idx = threadIdx.x + blockDim.x * blockIdx.x;

	if (idx >= n_elements)
		return;

	int input_idx = idx * 3;
	int output_idx = idx * 3;

	uint32_t faceId = *((uint32_t*) &training_batch[output_idx + 0]);

	result[input_idx + 0] = (float)faceId / (float)n_faces;
	result[input_idx + 1] = training_batch[output_idx + 1];
	result[input_idx + 2] = training_batch[output_idx + 2];

}

__global__ void generate_training_target(uint32_t n_elements, uint32_t n_faces, Material* materials, int* material_ids, float* training_batch, tinyobj::index_t* indices, float* texcoords, float* result) {

	int idx = threadIdx.x + blockDim.x * blockIdx.x;

	if (idx >= n_elements)
		return;

	int input_idx = idx * N_INPUT_DIMS;
	int output_idx = idx * N_OUTPUT_DIMS;

	int iv1, iv2, iv3, faceId;
	float w1, w2, w3;

	faceId = *((uint32_t*)&training_batch[input_idx + 0]);
	if (faceId < 0 || faceId >= n_faces) {
		result[output_idx + 0] = 0.f;
		result[output_idx + 1] = 0.f;
		result[output_idx + 2] = 0.f;

		result[output_idx + 3] = 0.f;
		result[output_idx + 4] = 0.f;
		result[output_idx + 5] = 0.f;
		return;
	}

	iv1 = indices[3 * faceId + 0].texcoord_index;
	iv2 = indices[3 * faceId + 1].texcoord_index;
	iv3 = indices[3 * faceId + 2].texcoord_index;

	w1 = training_batch[input_idx + 1];
	w2 = training_batch[input_idx + 2];
	w3 = 1.0f - w1 - w2;

	vec2 uv1, uv2, uv3;
	uv1 = vec2(texcoords[2 * iv1 + 0], texcoords[2 * iv1 + 1]);
	uv2 = vec2(texcoords[2 * iv2 + 0], texcoords[2 * iv2 + 1]);
	uv3 = vec2(texcoords[2 * iv3 + 0], texcoords[2 * iv3 + 1]);

	vec2 uv_interp = w1 * uv1 + w2 * uv2 + w3 * uv3;


	/*
	*	Load sample reference textures to construct training target.
	*
	*	result[output_idx + {0 .. N_OUTPUT_DIMS}] corresponds to each of the N_OUTPUT_DIMS channels
	*
	*	Modify the following code to sample the correct textures.
	*	Currently channels 0,1,2 represent albedo RGB (map_Kd) and channels 3,4,5 represent surface normals (map_Bump)
	*	See Material Template Library for reference.
	*/

	if (materials[material_ids[faceId]].map_Kd.valid) {
		cudaTextureObject_t texture_diffuse = materials[material_ids[faceId]].map_Kd.texture;
		float4 val_diff = tex2D<float4>(texture_diffuse, uv_interp.x, 1.0f - uv_interp.y);
		result[output_idx + 0] = val_diff.x;
		result[output_idx + 1] = val_diff.y;
		result[output_idx + 2] = val_diff.z;
	}
	else {
		result[output_idx + 0] = materials[material_ids[faceId]].diffuse[0];
		result[output_idx + 1] = materials[material_ids[faceId]].diffuse[1];
		result[output_idx + 2] = materials[material_ids[faceId]].diffuse[2];
	}
	if (materials[material_ids[faceId]].map_Bump.valid) {
		cudaTextureObject_t texture_bump = materials[material_ids[faceId]].map_Bump.texture;
		float4 val_bump = tex2D<float4>(texture_bump, uv_interp.x, 1.0f - uv_interp.y);
		result[output_idx + 3] = val_bump.x;
		result[output_idx + 4] = val_bump.y;
		result[output_idx + 5] = val_bump.z;
	}
	else {
		result[output_idx + 3] = 0.5f;
		result[output_idx + 4] = 0.5f;
		result[output_idx + 5] = 1.0f;
	}

}

std::vector<std::string> splitString(std::string input, char delimiter) {
	std::vector<std::string> result;
	std::istringstream stream(input);
	std::string token;

	while (std::getline(stream, token, delimiter)) {
		result.push_back(token);
	}

	return result;
}

EvalResult trainAndEvaluate(json config, GPUMemory<tinyobj::index_t>* indices, std::vector<tinyobj::index_t> indices_host,
	GPUMemory<float>* vertices, std::vector<float> vertices_host, GPUMemory<float>* texcoords, GPUMemory<float>* cdf,
	GPUMemory<Material>* materials, GPUMemory<int>* material_ids, std::vector<uint32_t> offsets, std::vector<uint32_t> meta,
	int sampleWidth, int sampleHeight, GPUMemory<float>* test_batch, long* training_time_ms,
	uint32_t training_iterations, std::string image_fname) {
	try {

		EvalResult res;

		/* =======================
		*  === TRAIN THE MODEL ===
		*  =======================
		*/

		// Various constants for the network and optimization
		const uint32_t batch_size = 1 << 18;

		const uint32_t n_training_steps = training_iterations + 1;

		cudaStream_t inference_stream;
		CUDA_CHECK_THROW(cudaStreamCreate(&inference_stream));
		cudaStream_t training_stream = inference_stream;

		default_rng_t rng{ 1337 };
		// Auxiliary matrices for training

		GPUMatrix<float> training_batch_raw(N_INPUT_DIMS, batch_size);
		GPUMatrix<float> training_batch(N_INPUT_DIMS, batch_size);
		GPUMatrix<float> training_target(N_OUTPUT_DIMS, batch_size);

		json encoding_opts = config.value("encoding", json::object());
		json loss_opts = config.value("loss", json::object());
		json optimizer_opts = config.value("optimizer", json::object());
		json network_opts = config.value("network", json::object());

		uint32_t n_vertices = vertices_host.size() / 3;
		uint32_t n_faces = indices_host.size() / 3;

		std::shared_ptr<Loss<precision_t>> loss{ create_loss<precision_t>(loss_opts) };
		std::shared_ptr<Optimizer<precision_t>> optimizer{ create_optimizer<precision_t>(optimizer_opts) };
		std::shared_ptr<Encoding<precision_t>> encoding{ create_vertex_encoding<precision_t>(N_INPUT_DIMS, n_vertices, n_faces, indices_host, vertices_host, offsets, meta, encoding_opts) };
		std::shared_ptr<NetworkWithInputEncoding<precision_t>> network = std::make_shared<NetworkWithInputEncoding<precision_t>>(encoding, N_OUTPUT_DIMS, network_opts);
		
		auto model = std::make_shared<Trainer<float, precision_t, precision_t>>(network, optimizer, loss);

		std::chrono::steady_clock::time_point begin = std::chrono::steady_clock::now();
		std::chrono::steady_clock::time_point end;


		float tmp_loss = 0;
		uint32_t tmp_loss_counter = 0;

		std::cout << "Beginning optimization with " << n_training_steps << " training steps." << std::endl;

		// RNG
		curandState* crs;
		cudaMalloc(&crs, sizeof(curandState) * batch_size);
		linear_kernel(setup_kernel, 0, training_stream, batch_size, crs);

		uint32_t interval = 10;

		for (uint32_t i = 0; i < n_training_steps; ++i) {
			bool print_loss = i % interval == 0;
			bool visualize_learned_func = /*(i % interval == 0) || */(i == (n_training_steps - 1));
			bool writeEvalResult = i == (n_training_steps - 1);

			/* ===============================
			*  === GENERATE TRAINING BATCH ===
			*  ===============================
			*/
			
			// Generate Surface Points - training input
			linear_kernel(generate_face_positions<precision_t>, 0, training_stream, batch_size, n_faces, crs, indices->data(), vertices->data(), cdf->data(), training_batch_raw.data());

			// Sample reference texture at surface points - training output
			linear_kernel(generate_training_target, 0, training_stream, batch_size, n_faces, materials->data(), material_ids->data(), training_batch_raw.data(), indices->data(), texcoords->data(), training_target.data());

			/* =========================
			*  === RUN TRAINING STEP ===
			*  =========================
			*/

			auto ctx_obj = model->training_step(training_stream, training_batch_raw, training_target);

			if (i % std::min(interval, (uint32_t)100) == 0) {
				tmp_loss += model->loss(training_stream, *ctx_obj);
				++tmp_loss_counter;
			}
			

			// Debug outputs
			{

				if (writeEvalResult) {
					res.MSE = tmp_loss / (float)tmp_loss_counter;
					res.n_floats = encoding.get()->n_params();
				}

				if (print_loss) {
					end = std::chrono::steady_clock::now();
					std::cout << "Step#" << i << ": " << "loss=" << tmp_loss / (float)tmp_loss_counter << " time=" << std::chrono::duration_cast<std::chrono::milliseconds>(end - begin).count() << "[ms]" << std::endl;

					tmp_loss = 0;
					tmp_loss_counter = 0;
				}

				if (visualize_learned_func) {

					// Auxiliary matrices for evaluation
					GPUMatrix<float> prediction(N_OUTPUT_DIMS, sampleWidth * sampleHeight);
					GPUMatrix<float> inference_batch(test_batch->data(), N_INPUT_DIMS, sampleWidth * sampleHeight);

					cudaThreadSynchronize();
					std::chrono::steady_clock::time_point evalStart = std::chrono::steady_clock::now();
					network->inference(inference_stream, inference_batch, prediction);
					cudaThreadSynchronize();
					std::chrono::steady_clock::time_point evalEnd = std::chrono::steady_clock::now();
					long evalTime = std::chrono::duration_cast<std::chrono::microseconds>(evalEnd - evalStart).count();
					std::cout << "Evaluation time = " << evalTime << "[microseconds]" << std::endl;
					res.EvalTime = evalTime;


					auto filename = fmt::format("nl{}_nf{}_nmf{}_nbins{}_niter{}.png",
						encoding_opts.value("n_levels", 1u), encoding_opts.value("n_features", 1u), std::log2(encoding_opts.value("max_features_level", 1u << 14)),
						encoding_opts.value("n_quant_bins", 16u), training_iterations - 5000u);
					save_images(prediction.data(), inference_batch.data(), sampleWidth, sampleHeight, image_fname/*filename*/);
				}
			}

			if (print_loss && i > 0 && interval < 1000) {
				interval *= 10;
			}
		}

		*training_time_ms = std::chrono::duration_cast<std::chrono::milliseconds>(end - begin).count();

		cudaFree(crs);
		free_all_gpu_memory_arenas();

		return res;
	}
	catch (const std::exception& e) {
		std::cout << "Uncaught exception: " << e.what() << std::endl;
		exit(1);
	}

}

void loadTexture(std::string path, Texture* tex) {

	try {
		tex->image = load_image(path, tex->width, tex->height);
	}
	catch (const std::exception& e) {
		tex->valid = false;
		return;
	}

	// Second step: create a cuda texture out of this image. It'll be used to generate training data efficiently on the fly
	memset(&tex->resDesc, 0, sizeof(tex->resDesc));
	tex->resDesc.resType = cudaResourceTypePitch2D;
	tex->resDesc.res.pitch2D.devPtr = tex->image.data();
	tex->resDesc.res.pitch2D.desc = cudaCreateChannelDesc(32, 32, 32, 32, cudaChannelFormatKindFloat);
	tex->resDesc.res.pitch2D.width = tex->width;
	tex->resDesc.res.pitch2D.height = tex->height;
	tex->resDesc.res.pitch2D.pitchInBytes = tex->width * 4 * sizeof(float);

	memset(&tex->texDesc, 0, sizeof(tex->texDesc));
	tex->texDesc.filterMode = cudaFilterModeLinear;
	tex->texDesc.normalizedCoords = true;
	tex->texDesc.addressMode[0] = cudaAddressModeClamp;
	tex->texDesc.addressMode[1] = cudaAddressModeClamp;
	tex->texDesc.addressMode[2] = cudaAddressModeClamp;

	CUDA_CHECK_THROW(cudaCreateTextureObject(&tex->texture, &tex->resDesc, &tex->texDesc, nullptr));

	tex->valid = true;
}

int main(int argc, char* argv[]) {
	
	uint32_t compute_capability = cuda_compute_capability();
	if (compute_capability < MIN_GPU_ARCH) {
		std::cerr
			<< "Warning: Insufficient compute capability " << compute_capability << " detected. "
			<< "This program was compiled for >=" << MIN_GPU_ARCH << " and may thus behave unexpectedly." << std::endl;
	}

	if (argc != 4) {
		std::cerr << "Usage: neural_surface <object_basedir> <object_filename> <sample_path>" << std::endl;
		exit(1);
	}


	/* =========================
	*  === LAUNCH PARAMETERS ===
	*  =========================
	*/

	std::string object_basedir = argv[1];
	std::string object_path = object_basedir + argv[2];
	std::string sample_path = argv[3];


	/* ======================
	*  === LOAD .OBJ FILE ===
	*  ======================
	*/

	std::cout << "Loading " << object_path << "..." << std::flush;
	tinyobj::attrib_t attrib;
	std::vector<tinyobj::shape_t> shapes;
	std::vector<tinyobj::material_t> mats;
	std::string err;
	std::string warn;
	// Expect '.mtl' file in the same directory and triangulate meshes
	bool ret = tinyobj::LoadObj(&attrib, &shapes, &mats, &warn, &err, object_path.c_str(), object_basedir.c_str());
	if (!err.empty())
	{ // `err` may contain warning message.
		std::cerr << err << std::endl;
	}
	if (!warn.empty())
	{
		std::cerr << warn << std::endl;
	}
	if (!ret)
	{
		std::cerr << "Loading .obj file failed." << std::endl;
		exit(1);
	}

	int shapeIndex = 0;
	tinyobj::mesh_t mesh = shapes[shapeIndex].mesh;
	int n_vertices = attrib.vertices.size() / 3;
	int n_texcoords = attrib.texcoords.size() / 2;

	int n_indices = mesh.indices.size();
	int n_faces = n_indices / 3;


	// Generate histogram of face areas to sample surface points
	std::vector<float> histogram(n_faces);
	float area_sum = 0.f;
	for (size_t i = 0; i < n_faces; i++) {
		vec3 v1(attrib.vertices[3 * mesh.indices[3 * i + 0].vertex_index + 0],
			attrib.vertices[3 * mesh.indices[3 * i + 0].vertex_index + 1],
			attrib.vertices[3 * mesh.indices[3 * i + 0].vertex_index + 2]);

		vec3 v2(attrib.vertices[3 * mesh.indices[3 * i + 1].vertex_index + 0],
			attrib.vertices[3 * mesh.indices[3 * i + 1].vertex_index + 1],
			attrib.vertices[3 * mesh.indices[3 * i + 1].vertex_index + 2]);

		vec3 v3(attrib.vertices[3 * mesh.indices[3 * i + 2].vertex_index + 0],
			attrib.vertices[3 * mesh.indices[3 * i + 2].vertex_index + 1],
			attrib.vertices[3 * mesh.indices[3 * i + 2].vertex_index + 2]);

		float area = 0.5f * length(cross(v2 - v1, v3 - v1));
		histogram[i] = area;
		area_sum += area;
	}

	// Create CDF from histogram
	std::vector<float> cdf_host(n_faces);
	float c_prob = 0.f;
	for (size_t i = 0; i < n_faces; i++) {
		c_prob += histogram[i] / area_sum;
		cdf_host[i] = c_prob;
	}

	// Compute vertex face list
	std::vector<uint32_t> offsets_host(2 * n_vertices);
	std::vector<uint32_t> meta_host;

	std::vector<std::vector<uint32_t>> adjFaces(n_vertices);
	std::vector<std::vector<uint32_t>> adjEdges(n_vertices);

	for (uint32_t i = 0; i < n_faces; i++) {

		uint32_t v0, v1, v2;
		v0 = shapes[shapeIndex].mesh.indices[3 * i + 0].vertex_index;
		v1 = shapes[shapeIndex].mesh.indices[3 * i + 1].vertex_index;
		v2 = shapes[shapeIndex].mesh.indices[3 * i + 2].vertex_index;

		adjFaces[v0].push_back(i);
		adjFaces[v1].push_back(i);
		adjFaces[v2].push_back(i);

		uint32_t vmin, vmax;

		vmin = min(v0, v1);
		vmax = max(v0, v1);

		auto it = adjEdges[vmin].empty() ? adjEdges[vmin].end() : std::find(adjEdges[vmin].begin(), adjEdges[vmin].end(), vmax);
		if (it == adjEdges[vmin].end()) {
			adjEdges[vmin].push_back(vmax);
			adjEdges[vmin].push_back(n_vertices + i);
			adjEdges[vmin].push_back(0xFFFFFFFF);
		}
		else {
			auto ind = std::distance(adjEdges[vmin].begin(), it) + 2;
			//adjEdges[vmin].at(ind) = i;
			adjEdges[vmin][ind] = n_vertices + i;
		}

		vmin = min(v0, v2);
		vmax = max(v0, v2);

		it = adjEdges[vmin].empty() ? adjEdges[vmin].end() : std::find(adjEdges[vmin].begin(), adjEdges[vmin].end(), vmax);
		if (it == adjEdges[vmin].end()) {
			adjEdges[vmin].push_back(vmax);
			adjEdges[vmin].push_back(n_vertices + i);
			adjEdges[vmin].push_back(0xFFFFFFFF);
		}
		else {
			auto ind = std::distance(adjEdges[vmin].begin(), it) + 2;
			//adjEdges[vmin].at(ind) = i;
			adjEdges[vmin][ind] = n_vertices + i;
		}

		vmin = min(v1, v2);
		vmax = max(v1, v2);

		it = adjEdges[vmin].empty() ? adjEdges[vmin].end() : std::find(adjEdges[vmin].begin(), adjEdges[vmin].end(), vmax);
		if (it == adjEdges[vmin].end()) {
			adjEdges[vmin].push_back(vmax);
			adjEdges[vmin].push_back(n_vertices + i);
			adjEdges[vmin].push_back(0xFFFFFFFF);
		}
		else {
			auto ind = std::distance(adjEdges[vmin].begin(), it) + 2;
			//adjEdges[vmin].at(ind) = i;
			adjEdges[vmin][ind] = n_vertices + i;
		}
			

		
	}

	for (size_t i = 0; i < n_vertices; i++) {
		offsets_host[i] = meta_host.size();
		meta_host.push_back(adjFaces[i].size());
		meta_host.insert(meta_host.end(), adjFaces[i].begin(), adjFaces[i].end());
	}

	for (size_t i = 0; i < n_vertices; i++) {
		offsets_host[n_vertices + i] = meta_host.size();
		meta_host.push_back(adjEdges[i].size());
		meta_host.insert(meta_host.end(), adjEdges[i].begin(), adjEdges[i].end());
	}


	// write vertices, indices and cdf to GPU memory
	GPUMemory<float> vertices(n_vertices * 3);
	vertices.copy_from_host(attrib.vertices);
	GPUMemory<float> texcoords(n_texcoords * 2);
	texcoords.copy_from_host(attrib.texcoords);
	GPUMemory<float> cdf(n_faces);
	cdf.copy_from_host(cdf_host);

	GPUMemory<tinyobj::index_t> indices(n_indices);
	std::vector<tinyobj::index_t> indices_host = shapes[shapeIndex].mesh.indices;
	indices.copy_from_host(indices_host);

	/* ==========================
	*  === LOAD MATERIAL DATA ===
	*  ==========================
	*/
	int n_materials = mats.size();
	std::vector<Material> materials_host(n_materials);
	GPUMemory<Material> materials(n_materials);
	GPUMemory<int> material_ids(n_faces);

	for (int i = 0; i < n_materials; i++) {
		materials_host[i].diffuse[0] = mats[i].diffuse[0];
		materials_host[i].diffuse[1] = mats[i].diffuse[1];
		materials_host[i].diffuse[2] = mats[i].diffuse[2];
		loadTexture(object_basedir + mats[i].diffuse_texname, &materials_host[i].map_Kd);
		loadTexture(object_basedir + mats[i].bump_texname, &materials_host[i].map_Bump);
	}

	materials.copy_from_host(materials_host);
	material_ids.copy_from_host(mesh.material_ids);
	std::cout << "Done." << std::endl;

	/* =======================
	*  === LOAD TEST INPUT ===
	*  =======================
	*/
	
	const bool testInput = true;

	// Vector to store the floats
		
	int sampleWidth, sampleHeight;
	sampleWidth = 0;
	sampleHeight = 0;
	std::vector<float> surface_positions;

	if (testInput) {
		std::cout << "Loading " << sample_path << "..." << std::flush;
		std::ifstream file(sample_path);

		if (!file.is_open()) {
			std::cerr << "Error opening file: " << sample_path << std::endl;
			return 1;
		}		

		// Read width and height
		std::string firstLine;	

		if (std::getline(file, firstLine)) {
			std::vector<std::string> w_and_h = splitString(firstLine, ',');
			sampleWidth = std::stoi(w_and_h[0]);
			sampleHeight = std::stoi(w_and_h[1]);
		}
		else {
			std::cerr << "Error reading sample.csv" << std::endl;
			return 1;
		}

		// Continue reading the remaining lines
		std::string line;
		while (std::getline(file, line)) {
			std::vector<std::string> s_pos = splitString(line, ',');
			uint32_t faceId = static_cast<uint32_t>(std::stoul(s_pos[0]));
			surface_positions.push_back(*((float*) &faceId));
			surface_positions.push_back(std::stof(s_pos[1]));
			surface_positions.push_back(std::stof(s_pos[2]));

		}

		// Close the file
		file.close();
		std::cout << "Done." << std::endl;
	}

	// Write surface_positions to GPU memory
	GPUMemory<float> test_batch(sampleWidth * sampleHeight * 3);
	test_batch.copy_from_host(surface_positions.data());

	if (testInput) {
			
		cudaStream_t test_generator_stream;
		CUDA_CHECK_THROW(cudaStreamCreate(&test_generator_stream));
		GPUMatrix<float> test_generator_batch(test_batch.data(), N_INPUT_DIMS, sampleWidth * sampleHeight);
		GPUMatrix<float> test_generator_result(N_OUTPUT_DIMS, sampleWidth * sampleHeight);
		linear_kernel(generate_training_target, 0, test_generator_stream, sampleWidth * sampleHeight, n_faces, materials.data(), material_ids.data(), test_generator_batch.data(), indices.data(), texcoords.data(), test_generator_result.data());

		auto filename = "reference.png";
		save_images(test_generator_result.data(), test_generator_batch.data(), sampleWidth, sampleHeight, filename);
			
	}


	/* =========================
		TRAINING AND EVALUATION
	   =========================
	*/
	

	json config = {
			{"loss", {
				{"otype", "RelativeL2"}
			}},
			{"optimizer", {
				{"otype", "Adam"},
				// {"otype", "Shampoo"},
				{"learning_rate", 1e-2},
				{"beta1", 0.9f},
				{"beta2", 0.99f},
				{"l2_reg", 0.0f},
				// The following parameters are only used when the optimizer is "Shampoo".
				{"beta3", 0.9f},
				{"beta_shampoo", 0.0f},
				{"identity", 0.0001f},
				{"cg_on_momentum", false},
				{"frobenius_normalization", true},
			}},
			{"encoding", {
				{"otype", "Vertex"},
				{"n_features", 2},					// F
				{"n_levels", 6},					// L
				{"max_features_level", 1u << 19},	// T
				{"n_quant_bins", 256},				// N
				{"n_quant_iterations", 0}			// Iterations after features are quantized, 0 = quantization disabled
			}},
			{"network", {
				{"otype", "FullyFusedMLP"},
				// {"otype", "CutlassMLP"},
				{"n_neurons", 64},
				{"n_hidden_layers", 4},
				{"activation", "ReLU"},
				{"output_activation", "None"},
			}},
	};

	long training_time_ms;
	json encoding_opts = config.value("encoding", json::object());
	std::cout << fmt::format("Starting training with hyperparameters:\nF = {} | L = {} | T = {} ...\n",
		encoding_opts.value("n_features", 1u), encoding_opts.value("n_levels", 1u), encoding_opts.value("max_features_level", 1u));

	EvalResult res = trainAndEvaluate(config, &indices, indices_host, &vertices, attrib.vertices, &texcoords, &cdf,
		&materials, &material_ids, offsets_host, meta_host, sampleWidth, sampleHeight, &test_batch, &training_time_ms, 5000, "neural.png");

	std::cout << fmt::format("Finished training after {} ms.\nMSE = {}\nEvaluation time = {} [microseconds]\nn_params = {}\n",
		training_time_ms, res.MSE, res.EvalTime, res.n_floats);


	return EXIT_SUCCESS;
}

