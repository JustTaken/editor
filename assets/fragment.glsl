#version 460 core

out vec4 color;

layout (binding = 2) uniform sampler2DArray textureSampler1;

in Vertex {
    vec2 outTexture;
    flat int textureIndex;
};

void main() {
    vec4 tex = texture(textureSampler1, vec3(outTexture, textureIndex));
    color = vec4(1.0, 1.0, 1.0, tex.r);
    // color = vec4(tex.r, 1.0, 1.0, 1.0);
}
