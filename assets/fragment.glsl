#version 460 core

out vec4 color;
in vec3 outColor;
in vec2 outTexture;

uniform sampler2D textureSampler1;
uniform sampler2D textureSampler2;

void main() {
    color = mix(texture(textureSampler1, outTexture), texture(textureSampler2, outTexture), 0.2f);
}
