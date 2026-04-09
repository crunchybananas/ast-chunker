#ifndef C_TREE_SITTER_GLIMMER_H_
#define C_TREE_SITTER_GLIMMER_H_

// Forward-declare TSLanguage (defined in CTreeSitter)
typedef struct TSLanguage TSLanguage;

#ifdef __cplusplus
extern "C" {
#endif

const TSLanguage *tree_sitter_glimmer_typescript(void);

#ifdef __cplusplus
}
#endif

#endif // C_TREE_SITTER_GLIMMER_H_
