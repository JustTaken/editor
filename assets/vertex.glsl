#version 460 core

layout (location = 0) in vec3 vPos;
layout (location = 1) in vec3 vColor;
layout (location = 2) in vec2 vTexture;

out vec3 outColor;
out vec2 outTexture;

void main() {
    gl_Position = vec4(vPos, 1.f);
    outColor = vColor;
    outTexture = vTexture;
}
