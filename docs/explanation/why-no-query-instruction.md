# Explanation: why a query has no instruction

Some embedding models are trained to expect a prefix on a query, such as "Represent this sentence for searching relevant passages:", and a different one (or none) on a document. A plugin could add such a prefix to your search words.

This plugin does not. `:NoteRetrieval search` embeds exactly the words you typed.

The reason is the index. The index of the Obsidian plugin Vault Retrieval holds the vectors of the raw text of the notes, made without any instruction, and the own index of this plugin follows the same format so that both can be read by both. A query is compared with those vectors. If the query carried an instruction that the notes did not, you would compare two different kinds of text, and for a model that was not trained for it the prefix is noise in the vector.

What you give up: a model that is built for query prefixes may rank slightly better with one. What you get: one rule that holds for both modes and every model, and a result you can reproduce by embedding the same words by hand.

The self-find probe (`:NoteRetrieval probe`) works the same way. It searches with the first 300 units of a note's own text, with nothing in front, and expects the note itself back at rank 0.
