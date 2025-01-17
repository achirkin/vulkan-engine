#version 450
#extension GL_ARB_separate_shader_objects : enable

layout(set = 1, binding = 0) uniform sampler2D texSampler;

layout(location = 0) in vec2 fragTexCoord;

layout(location = 0) out vec4 outColor;

void main() {
  // outColor = vec4(fragColor, 1.0);
  outColor = texture(texSampler, fragTexCoord);
  // outColor = vec4(fragColor * texture(texSampler, fragTexCoord * 2.0).rgb, 1.0);
}
