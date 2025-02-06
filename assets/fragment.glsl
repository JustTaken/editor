#version 460 core

out vec4 color;

layout (binding = 2) uniform sampler2D textureSampler1;
// layout (binding = 3) uniform sampler2D textureSampler2;

in vec3 outColor;
in vec2 outTexture;

void main() {
    // vec4 mixture = mix(texture(textureSampler1, outTexture), texture(textureSampler2, outTexture), 0.2f);
    color = texture(textureSampler1, outTexture);
}
