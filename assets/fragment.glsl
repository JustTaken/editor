#version 460 core

out vec4 color;

layout (binding = 1) uniform sampler2D textureSampler1;

in vec2 outTexture;

void main() {
    color = vec4(1.0, 1.0, 1.0, texture(textureSampler1, outTexture).r);
}
