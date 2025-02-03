#version 460 core

out vec4 color;
in vec3 outColor;
in vec2 outTexture;

uniform sampler2D textureSampler;
uniform sampler2D textureSampler2;

void main() {
    color = mix(texture(textureSampler, outTexture), texture(textureSampler2, outTexture), 0.2);
}
