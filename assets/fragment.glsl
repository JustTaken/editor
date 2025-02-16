#version 460 core

out vec4 color;

layout (binding = 2) uniform sampler2DArray textureSampler1;

in Vertex {
    vec2 outTexture;
    flat int textureIndex;
};

void main() {
    // color = vec4(1.0, 1.0, 1.0, texture(textureSampler1, vec3(outTexture, textureIndex)).r);
    float tex = texture(textureSampler1, vec3(outTexture, textureIndex)).r;
    float aaf = fwidth(tex);
    float alpha = smoothstep(0.33 - aaf, 0.33 + aaf, tex);
    color = vec4(1.0, 1.0, 1.0, alpha);
    // color = vec4(1.0, alpha, 1.0, 1.0);
}
