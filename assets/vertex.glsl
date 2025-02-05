#version 460 core

layout (location = 0) in vec3 vPos;
layout (location = 1) in vec3 vColor;
layout (location = 2) in vec2 vTexture;
layout (location = 3) in vec3 iPos;

out vec3 outColor;
out vec2 outTexture;

uniform mat4 modelMatrix;
uniform mat4 viewMatrix;
uniform mat4 projectionMatrix;

void main() {
    // vec3 iPos = vec3(1.0f);
    // vec4 p = vec4(iPos, 1.0f);
    gl_Position = vec4(vPos + iPos, 1.0f) * modelMatrix * viewMatrix * projectionMatrix;
    outColor = vColor;
    outTexture = vTexture;
}
