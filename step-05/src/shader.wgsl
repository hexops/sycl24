struct VertexOutput {
  @builtin(position) position: vec4<f32>,
  @location(0) uv: vec2<f32>,
};

@vertex
fn vertex_main(
  @location(0) position: vec2<f32>,
  @location(1) uv: vec2<f32>
) -> VertexOutput {
  var output: VertexOutput;
  output.position = vec4(position, 0, 1);
  output.uv = uv;
  return output;
}

@group(0) @binding(0) var quad_sampler: sampler;
@group(0) @binding(1) var quad_texture: texture_2d<f32>;

@fragment
fn frag_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
    return textureSample(quad_texture, quad_sampler, uv);
}