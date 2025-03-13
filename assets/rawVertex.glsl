#version 460 core

layout (location = 0) in vec3 vPos;
layout (location = 1) in vec3 vNormal;
layout (location = 2) in vec2 vTexture;

layout(std430, binding = 0) readonly buffer InstanceTransform {
    mat4 instanceTransforms[];
};

layout(std430, binding = 1) readonly buffer ColorTransform {
    vec4 colorTransforms[];
};

layout (binding = 0) uniform Matrix {
    mat4 viewMatrix;
    mat4 projectionMatrix;
};

out Vertex {
    vec4 outColor;
    vec2 outTexture;
    flat int textureIndex;
};

void main() {
    int instanceId = gl_InstanceID + gl_BaseInstance;

    gl_Position = vec4(vPos, 1.0) * instanceTransforms[instanceId] * viewMatrix * projectionMatrix;

    outTexture = vTexture;
    outColor = colorTransforms[instanceId];
}
