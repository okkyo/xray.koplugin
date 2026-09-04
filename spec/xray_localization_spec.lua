-- xray_localization_spec.lua
require("spec.spec_helper")
local Localization = require("localization_xray")

-- Write a throwaway .po file and read it back through parsePO.
local function parse_po_text(text)
    local path = spec_tmpname()
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
    local out = Localization:parsePO(path)
    os.remove(path)
    return out
end

describe("localization_xray parsePO escape decoding", function()
    -- The reader must stay the exact inverse of po_escape in
    -- tools/sync_translations.py, or a sync grows the escapes it writes.
    it("decodes newlines, tabs, quotes, and backslashes", function()
        local t = parse_po_text([[
msgid "nl"
msgstr "line one\nline two"

msgid "tab"
msgstr "a\tb"

msgid "quoted"
msgstr "use \"Fetch X-Ray Data\" first"

msgid "slash"
msgstr "back\\slash"
]])
        assert.are.equal("line one\nline two", t.nl)
        assert.are.equal("a\tb", t.tab)
        assert.are.equal('use "Fetch X-Ray Data" first', t.quoted)
        assert.are.equal("back\\slash", t.slash)
    end)

    -- Regression: a chain of gsubs decodes the output of the previous gsub, so
    -- an escaped backslash followed by the letter n came out as a backslash and
    -- a real newline.
    it("does not decode an escaped backslash twice", function()
        local t = parse_po_text('msgid "k"\nmsgstr "a\\\\nb"\n')
        assert.are.equal("a\\nb", t.k)
        assert.is_nil(t.k:find("\n", 1, true))
    end)

    it("leaves an unknown escape alone", function()
        local t = parse_po_text('msgid "k"\nmsgstr "50\\% done"\n')
        assert.are.equal("50\\% done", t.k)
    end)
end)

describe("localization_xray parsePO value extraction", function()
    -- Regression: a lazy "(.-)" capture ended the value at the first escaped
    -- quote, so a translation with an embedded quote was cut off.
    it("keeps the whole value when it contains escaped quotes", function()
        local t = parse_po_text(
            'msgid "k"\nmsgstr "Utilizza prima \\"Recupera dati\\" per iniziare."\n')
        assert.are.equal('Utilizza prima "Recupera dati" per iniziare.', t.k)
    end)

    it("joins continuation lines that contain escaped quotes", function()
        local t = parse_po_text(
            'msgid "k"\nmsgstr ""\n"first \\"one\\" "\n"second \\"two\\""\n')
        assert.are.equal('first "one" second "two"', t.k)
    end)

    it("reads every real translation file without truncating a value", function()
        local dir = "xray.koplugin/languages"
        local count = 0
        for _, code in ipairs({ "en", "it", "de", "ja", "zh_CN" }) do
            local t = Localization:parsePO(dir .. "/" .. code .. ".po")
            assert.is_not_nil(t, code .. ".po must parse")
            for key, value in pairs(t) do
                -- A truncated value ends in the stray backslash the old lazy
                -- capture left behind.
                assert.is_nil(value:match("\\$"),
                    code .. "." .. key .. " ends in a stray backslash")
                count = count + 1
            end
        end
        assert.is_true(count > 1000)
    end)
end)
