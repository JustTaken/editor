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

layout(std430, binding = 2) readonly buffer InstanceDepth {
    float depthTransforms[];
};

layout(std430, binding = 3) readonly buffer InstanceDepthIndex {
    uint instanceDepthIndices[];
};

layout(std430, binding = 4) readonly buffer InstanceScale {
    mat4 instanceScale[];
};

layout(std430, binding = 5) readonly buffer InstanceScaleIndex {
    uint instanceScaleIndices[];
};

layout(std430, binding = 6) readonly buffer ColorTransform {
    vec4 colorTransforms[];
};

layout(std430, binding = 7) readonly buffer ColorTransformIndex {
    uint colorTransformIndices[];
};

layout (binding = 2) uniform Scale {
    float worldScale;
    float screenScale;
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
    int instanceIndice = int(int(instanceTransformIndices[instanceId / 2]) >> (16 * (instanceId % 2))) & 0xFFFF;
    int scaleIndice = int(int(instanceScaleIndices[instanceId / 4]) >> (8 * (instanceId % 4))) & 0xFF;
    int colorIndice = int(int(colorTransformIndices[instanceId / 4]) >> (8 * (instanceId % 4))) & 0xFF;
    int depthIndice = int(int(instanceDepthIndices[instanceId / 4]) >> (8 * (instanceId % 4))) & 0xFF;

    mat4 transform = mat4(1.0);
    transform[0][3] = instanceTransforms[instanceIndice].x;
    transform[1][3] = instanceTransforms[instanceIndice].y;
    transform[2][3] = depthTransforms[depthIndice];

    mat4 model = mat4(1.0);
    model[0][0] = worldScale;
    model[1][1] = worldScale;
    model = model * instanceScale[scaleIndice] * transform;

    mat4 scale = mat4(1.0);
    scale[0][0] = screenScale;
    scale[1][1] = screenScale;

    gl_Position = vec4(vPos, 1.0) * model * viewMatrix * scale * projectionMatrix;

    outTexture = vTexture;
    outColor = colorTransforms[colorIndice];
}
