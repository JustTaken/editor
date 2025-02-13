#version 460 core

layout (location = 0) in vec3 vPos;
layout (location = 1) in vec3 vNormal;
layout (location = 2) in vec2 vTexture;

layout(std430, binding = 0) readonly buffer InstanceTransform {
    vec2 instanceTransforms[];
};
layout(std430, binding = 1) readonly buffer InstanceTransformIndex {
    uint instanceTransformIndices[];
};

layout(std430, binding = 2) readonly buffer CharTransform {
    vec2 charTransforms[];
};

layout(std430, binding = 3) readonly buffer CharTransformIndex {
    uint charTransformIndices[];
};

layout (binding = 2) uniform Scale {
    float worldScale;
    float screeScale;
};

layout (binding = 0) uniform Matrix {
    mat4 viewMatrix;
    mat4 projectionMatrix;
};

out Vertex {
    vec2 outTexture;
    flat int textureIndex;
};

void main() {
    int instanceId = gl_InstanceID + gl_BaseInstance;
    int instanceIndice = int(int(instanceTransformIndices[instanceId / 2]) >> (16 * (instanceId % 2))) & 0xFFFF;
    int textureIndice = int(int(charTransformIndices[instanceId / 4]) >> (8 * (instanceId % 4))) & 0xFF;

    vec4 pos = vec4(worldScale * vPos.xy + instanceTransforms[instanceIndice] + charTransforms[textureIndice], 0.0, 1.0) * viewMatrix;
    gl_Position =  vec4(pos.xy * screeScale, pos.z, 1.0) * projectionMatrix;

    outTexture = vTexture;
    textureIndex = textureIndice;
}
