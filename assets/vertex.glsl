#version 460 core

layout (location = 0) in vec3 vPos;
layout (location = 1) in vec3 vNormal;
layout (location = 2) in vec2 vTexture;

layout(std430, binding = 0) readonly buffer instanceModel {
    mat4 model[];
};

layout(std430, binding = 1) readonly buffer modelIndex {
    uint indices[];
};

layout (binding = 0) uniform Matrix {
    mat4 modelMatrix;
    mat4 viewMatrix;
    mat4 projectionMatrix;
};

out Vertex {
    vec2 outTexture;
    flat int textureIndex;
};

void main() {
    gl_Position = vec4(vPos , 1.0f) * modelMatrix * model[gl_InstanceID + gl_BaseInstance] * viewMatrix * projectionMatrix;

    outTexture = vTexture;
    textureIndex = int(indices[gl_InstanceID + gl_BaseInstance]);
}
