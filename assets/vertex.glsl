#version 460 core

layout (location = 0) in vec3 vPos;
layout (location = 1) in vec3 vNormal;
layout (location = 2) in vec2 vTexture;

layout(binding = 0) buffer iModel {
    mat4 model[];
};

layout (binding = 0) uniform Matrix {
    mat4 modelMatrix;
    mat4 viewMatrix;
    mat4 projectionMatrix;
};

out vec2 outTexture;

void main() {
    gl_Position = vec4(vPos , 1.0f) * model[gl_InstanceID] * modelMatrix * viewMatrix * projectionMatrix;
    outTexture = vTexture;
}
