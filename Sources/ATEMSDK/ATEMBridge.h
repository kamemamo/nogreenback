// Blackmagic の ATEM Switchers SDK を Swift から使うための、C の窓口
// SDK 本体は ATEM のソフト (Blackmagic ATEM Switchers) を入れると
// /Library/Application Support/Blackmagic Design/Switchers/BMDSwitcherAPI.bundle に入る。
// 入っていない Mac では atem_sdk_available() が 0 を返す

#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ATEMSDK ATEMSDK;

/// SDK を使えるか (ATEM のソフトが入っているか)
int atem_sdk_available(void);

/// つなぐ (数秒かかることがある)。address が空なら USB だけでつなぐ。
/// IP アドレスでつながらないときも、SDK が USB を試す。失敗したら NULL
ATEMSDK *atem_sdk_connect(const char *address, int32_t *failReason);
void atem_sdk_release(ATEMSDK *s);

/// 切れたら 0
int atem_sdk_is_connected(ATEMSDK *s);
void atem_sdk_product_name(ATEMSDK *s, char *buf, int len);

/// 外部の入力 (HDMI / SDI) の数、ID、名前
int atem_sdk_input_count(ATEMSDK *s);
int64_t atem_sdk_input_id(ATEMSDK *s, int index);
void atem_sdk_input_name(ATEMSDK *s, int index, char *buf, int len);

/// 本番 (PGM) の入力 (取れなければ -1)
int64_t atem_sdk_program(ATEMSDK *s);
int atem_sdk_set_program(ATEMSDK *s, int64_t input);
int atem_sdk_set_preview(ATEMSDK *s, int64_t input);
int atem_sdk_auto(ATEMSDK *s);
/// ミックスの長さを秒で決める (映像のフレームレートからフレーム数に直す)
int atem_sdk_set_mix_seconds(ATEMSDK *s, double seconds);

#ifdef __cplusplus
}
#endif
