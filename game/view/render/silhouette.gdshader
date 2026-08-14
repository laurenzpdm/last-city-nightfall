shader_type canvas_item;

// Silhouette-only draw. [P13]
//
// The shadow pass draws the building sprites themselves, squashed and offset
// along the key, so a structure casts the shape it actually has instead of a
// soft round smudge. Straight modulation cannot do that: draw_texture_rect_region
// MULTIPLIES the atlas RGB, so a pale roof would cast a pale shadow and a rusty
// tank a rust-coloured one. This throws the atlas colour away and keeps only its
// coverage, which is the definition of a silhouette.
//
// One material on the pass node, so every shadow in the frame is still one batch
// out of one texture.

void fragment() {
	COLOR = vec4(COLOR.rgb, texture(TEXTURE, UV).a * COLOR.a);
}
