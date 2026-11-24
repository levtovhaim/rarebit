-- Categories and their word lists. Only `validator migrate` writes these tables, from
-- data/categories/*.json; the keys are computed by native/hebrew-normalize at load time.
-- Categories are upserted, never dropped and recreated, so later tables can reference them.

CREATE TABLE categories (
    id   text PRIMARY KEY CHECK (id ~ '^[a-z][a-z0-9_-]*$'),
    name text NOT NULL,
    kind text NOT NULL CHECK (kind IN ('regular', 'creative'))
);

CREATE TABLE word_lists (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_id text NOT NULL REFERENCES categories (id) ON DELETE CASCADE,
    position    int  NOT NULL,
    source      text NOT NULL,
    license     text NOT NULL,
    url         text,
    query       text,
    retrieved   text,
    UNIQUE (category_id, position)
);

CREATE TABLE words (
    category_id  text   NOT NULL REFERENCES categories (id) ON DELETE CASCADE,
    word         text   NOT NULL,
    norm_key     text   NOT NULL,
    spelling_key text,  -- NULL when the key has fewer than 3 letters: no variant match
    first_letter text   NOT NULL,
    key_letters  int    NOT NULL,
    list_id      bigint NOT NULL REFERENCES word_lists (id) ON DELETE CASCADE,
    PRIMARY KEY (category_id, word)
);

CREATE INDEX words_by_key ON words (category_id, norm_key);
CREATE INDEX words_by_spelling_key ON words (category_id, spelling_key) WHERE spelling_key IS NOT NULL;
CREATE INDEX words_by_length ON words (category_id, first_letter, key_letters);

-- One row per content load: what was loaded and which normalizer computed the keys.
CREATE TABLE content_loads (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loaded_at          timestamptz NOT NULL DEFAULT now(),
    categories         int  NOT NULL,
    words              int  NOT NULL,
    content_sha256     text NOT NULL,
    normalizer_version text NOT NULL,
    unicode_version    text NOT NULL
);
