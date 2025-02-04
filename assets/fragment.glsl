#version 460 core

out vec4 color;
in vec3 outColor;
in vec2 outTexture;

uniform sampler2D textureSampler1;

void main() {
    color = texture(textureSampler1, outTexture);
}
