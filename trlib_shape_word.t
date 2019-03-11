
--Shaping a single word into a cached array of glyphs called a glyph run.

if not ... then require'trlib_test'; return end

setfenv(1, require'trlib_types')
require'trlib_font'
require'trlib_rle'

--interface with the LRU cache

terra GlyphRun:__hash32()
	var h = hash32(self + GlyphRun_key_offset, GlyphRun_key_size, 0)
	h = self.text:__hash32(h)
	h = self.features:__hash32(h)
end

terra GlyphRun:__equal(other: &GlyphRun)
	return memcmp(
			self  + GlyphRun_key_offset,
			other + GlyphRun_key_offset, GlyphRun_key_size) == 0
		and self.text == other.text
		and self.features == other.features
end

terra GlyphRun:__memsize()
	return sizeof(GlyphRun)
		+ self.text:__memsize()
		+ self.features:__memsize()
		+ (sizeof(cursor_offset_t) + sizeof(cursor_x_t)) * (self.text.len + 1)
		+ (sizeof(hb_glyph_info_t) + sizeof(hb_glyph_position_t)) * self.len
end

terra GlyphRun:free()
	hb_buffer_destroy(self.hb_buf)
	free(self.cursor_xs)
	free(self.cursor_offsets)
	self.font:unref()
	self.text:free()
	self.features:free()
	fill(self)
end

terra GlyphRun:shape()
	if not self.font:ref() then return false end
	self.font:setsize(self.font_size)

	self.text = self.text:copy()
	self.features = self.features:copy()

	var hb_dir = iif(self.rtl, HB_DIRECTION_RTL, HB_DIRECTION_LTR)
	self.hb_buf = hb_buffer_create()
	hb_buffer_set_cluster_level(self.hb_buf,
		--HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS
		HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES
		--HB_BUFFER_CLUSTER_LEVEL_CHARACTERS
	)
	hb_buffer_set_direction(self.hb_buf, hb_dir)
	hb_buffer_set_script(self.hb_buf, self.script)
	hb_buffer_set_language(self.hb_buf, self.lang)
	hb_buffer_add_codepoints(self.hb_buf, self.text.elements, self.text.len, 0, self.text.len)
	hb_shape(self.font.hb_font, self.hb_buf, self.features.elements, self.features.len)

	self.len  = hb_buffer_get_length(self.hb_buf)
	self.info = hb_buffer_get_glyph_infos(self.hb_buf, nil)
	self.pos  = hb_buffer_get_glyph_positions(self.hb_buf, nil)

	--1. scale advances and offsets based on `font.scale` (for bitmap fonts).
	--2. make the advance of each glyph relative to the start of the run
	--   so that pos_x() is O(1) for any index.
	--3. compute the run's total advance.
	var ax: int = 0
	for i = 0, self.len do
		ax = (ax + self.pos[i].x_advance) * self.font.scale
		self.pos[i].x_offset = self.pos[i].x_offset * self.font.scale
		self.pos[i].x_advance = ax
	end
	self.advance_x = [num](ax) / 64 --for positioning in horizontal flow

	self.ascent = self.font.ascent
	self.descent = self.font.descent

	return true
end

--iterate clusters in RLE-compressed form.
local c1 = symbol(uint32)
local c0 = symbol(uint32)
local clusters_iter = rle_iterator{
	state = &GlyphRun,
	for_variables = {c0},
	declare_variables = function()        return quote var [c1], [c0] end end,
	save_values       = function()        return quote c0 = c1 end end,
	load_values       = function(self, i) return quote c1 = self.info[i].cluster end end,
	values_different  = function()        return `c0 ~= c1 end,
}
GlyphRun.methods.cluster_runs = macro(function(self)
	return `clusters_iter{&self, 0, self.len}
end)

local terra count_graphemes(grapheme_breaks: &int8, start: int, len: int)
	var n = 0
	for i = start, start+len do
		if grapheme_breaks[i] == 0 then
			n = n + 1
		end
	end
	return n
end

local terra next_grapheme(grapheme_breaks: &int8, i: int, len: int)
	while grapheme_breaks[i] ~= 0 do
		i = i + 1
	end
	i = i + 1
	assert(i < len)
	return i
end

local get_ligature_carets = macro(function(
	tr, hb_font, direction, glyph_index
)
	return quote
		var count = hb_ot_layout_get_ligature_carets(hb_font, direction,
			glyph_index, 0, nil, nil)
		tr.carets_buffer.len = count
		var count_buf: uint
		hb_ot_layout_get_ligature_carets(hb_font, direction, glyph_index,
			0, &count_buf, tr.carets_buffer.elements)
	in
		tr.carets_buffer.elements, count_buf
	end
end)

terra GlyphRun:pos_x(i: int)
	assert(i >= 0 and i <= self.len)
	return iif(i > 0, self.pos[i-1].x_advance / 64, 0)
end

terra GlyphRun:_add_cursors(
	tr: &TextRenderer,
	glyph_offset: int,
	glyph_len: int,
	cluster: int,
	cluster_len: int,
	cluster_x: num,
	--closure environment
	str: &codepoint,
	str_len: int
)
	self.cursor_offsets[cluster] = cluster
	self.cursor_xs[cluster] = cluster_x
	if cluster_len <= 1 then return end

	--the cluster is made of multiple codepoints. check how many
	--graphemes it contains since we need to add additional cursor
	--positions at each grapheme boundary.
	tr.grapheme_breaks.len = str_len
	var lang = nil --not used in current libunibreak impl.
	set_graphemebreaks_utf32(str, str_len, lang, tr.grapheme_breaks.elements)
	var grapheme_count = count_graphemes(tr.grapheme_breaks.elements, cluster, cluster_len)
	if grapheme_count <= 1 then return end

	--the cluster is made of multiple graphemes, which can be the
	--result of forming ligatures, which the font can provide carets
	--for. missing ligature carets, we divide the combined x-advance
	--of the glyphs evenly between graphemes.
	for i = glyph_offset, glyph_offset + glyph_len - 1 do
		var glyph_index = self.info[i].codepoint
		var cluster_x = self:pos_x(i)
		var carets, caret_count =
			get_ligature_carets(
				tr,
				self.font.hb_font,
				iif(self.rtl, HB_DIRECTION_RTL, HB_DIRECTION_LTR),
				glyph_index)
		if caret_count > 0 then
			-- there shouldn't be more carets than grapheme_count-1.
			caret_count = min(caret_count, grapheme_count - 1)
			--add the ligature carets from the font.
			for i = 0, caret_count-1 do
				--create a synthetic cluster at each grapheme boundary.
				cluster = next_grapheme(tr.grapheme_breaks.elements, cluster, str_len)
				var lig_x = carets[i] / 64
				self.cursor_offsets[cluster] = cluster
				self.cursor_xs[cluster] = cluster_x + lig_x
			end
			--infer the number of graphemes in the glyph as being
			--the number of ligature carets in the glyph + 1.
			grapheme_count = grapheme_count - (caret_count + 1)
		else
			--font doesn't provide carets: add synthetic carets by
			--dividing the total x-advance of the remaining glyphs
			--evenly between remaining graphemes.
			var next_i = glyph_offset + glyph_len
			var total_advance_x = self:pos_x(next_i) - self:pos_x(i)
			var w = total_advance_x / grapheme_count
			for i = 1, grapheme_count-1 do
				--create a synthetic cluster at each grapheme boundary.
				cluster = next_grapheme(tr.grapheme_breaks.elements, cluster, str_len)
				var lig_x = i * w
				self.cursor_offsets[cluster] = cluster
				self.cursor_xs[cluster] = cluster_x + lig_x
			end
			grapheme_count = 0
		end
		if grapheme_count == 0 then
			break --all graphemes have carets
		end
	end
end

terra GlyphRun:compute_cursors(tr: &TextRenderer)

	self.cursor_offsets = new(int16, self.text.len + 1) --in logical order
	self.cursor_xs = new(num, self.text.len + 1) --in logical order
	for i = 0, self.text.len + 1 do
		self.cursor_offsets[i] = -1 --invalid offset, fixed later
	end

	var grapheme_breaks: &int8 --allocated on demand for multi-codepoint clusters

	if self.rtl then
		--add last logical (first visual), after-the-text cursor
		self.cursor_offsets[self.text.len] = self.text.len
		self.cursor_xs[self.text.len] = 0
		var i: int = -1 --index in glyph_info
		var n: int --glyph count
		var c: int --cluster
		var cn: int --cluster len
		var cx: num --cluster x
		c = self.text.len
		for i1, n1, c1 in self:cluster_runs() do
			cx = self:pos_x(i1)
			if i ~= -1 then
				self:_add_cursors(tr, i, n, c, cn, cx, self.text.elements, self.text.len)
			end
			var cn1 = c - c1
			i, n, c, cn = i1, n1, c1, cn1
		end
		if i ~= -1 then
			cx = self.advance_x
			self:_add_cursors(tr, i, n, c, cn, cx, self.text.elements, self.text.len)
		end
	else
		var i: int = -1 --index in glyph_info
		var n: int --glyph count
		var c: int = -1 --cluster
		var cx: num --cluster x
		for i1, n1, c1 in self:cluster_runs() do
			if c ~= -1 then
				var cn = c1 - c
				self:_add_cursors(tr, i, n, c, cn, cx, self.text.elements, self.text.len)
			end
			var cx1 = self:pos_x(i1)
			i, n, c, cx = i1, n1, c1, cx1
		end
		if i ~= -1 then
			var cn = self.text.len - c
			self:_add_cursors(tr, i, n, c, cn, cx, self.text.elements, self.text.len)
		end
		--add last logical (last visual), after-the-text cursor
		self.cursor_offsets[self.text.len] = self.text.len
		self.cursor_xs[self.text.len] = self.advance_x
	end

	--add cursor offsets for all codepoints which are missing one.
	if grapheme_breaks ~= nil then --there are clusters with multiple codepoints.
		var c: int --cluster
		var x: num --cluster x
		for i = 0, self.text.len + 1 do
			if self.cursor_offsets[i] == -1 then
				self.cursor_offsets[i] = c
				self.cursor_xs[i] = x
			else
				c = self.cursor_offsets[i]
				x = self.cursor_xs[i]
			end
		end
	end

	--compute `wrap_advance_x` by removing the advance of the trailing space.
	var wx = self.advance_x
	if self.trailing_space then
		var i = iif(self.rtl, 0, self.len-1)
		assert(self.info[i].cluster == self.text.len-1)
		wx = wx - (self:pos_x(i+1) - self:pos_x(i))
	end
	self.wrap_advance_x = wx
end

terra TextRenderer:shape_word(glyph_run: GlyphRun)
	--get the shaped run from cache or shape it and cache it.
	var pair = self.glyph_runs:get(glyph_run)
	if pair == nil then
		if not glyph_run:shape() then return nil end
		glyph_run:compute_cursors(self)
		pair = self.glyph_runs:put(glyph_run, true)
	end
	return &pair.key
end
