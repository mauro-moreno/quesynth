---
source_url:
  - https://daichilab.sakura.ne.jp/softsynth/synmanu/readmeeng.html
  - https://daichilab.sakura.ne.jp/softsynth/synmanu/readme.html
  - https://daichilab.sakura.ne.jp/synthprog/index.html
  - https://robertheaton.com/2019/04/21/synth1-unofficial-manual/
  - https://sound.eti.pg.gda.pl/student/eim/doc/Synth1.pdf
fetched_at: 2026-08-23
fetch_method: fetch_content + curl/iconv (Shift-JIS pages) + PDF text extraction
topic: Synth1 oscillator modulation envelope (params 10/11/12/13/71) documentation excerpts
---

# Daichi official English readme (readmeeng.html)

> The pitch of oscillator2 ,FM and pulse width can be varied over time using modulation envelopes.

> m.env | Switch the modulation envelope ON/OFF. When on, the follwing destination of modulation varies over time according to the settings of A, D and amt below.
> dest. | Select pitch of oscillator2, FM or pulse width as the destinaion of modulation env.
> A | Set the attack time of the modulation envelope.
> D | Set the decay time of the modulation envelope.
> amt | Set the amount of modulation variation when modulation envelope is on. Right of the centre raises the amount, left of the centre lowers the amount. The centre setting results in no modulation variation.

Version history (English readme), Ver1.05a (2002.11.17):

> about sound ... Modulation envelope -> FM,Pulse Width
> BugFix ... modify mod env max value
> ... modify pitch env & portament combination

No octave/semitone/cent range is stated anywhere for the mod-env amount.

# Daichi official Japanese readme (readme.html)

> また、モジュレーションエンベロープ機能により、オシレータ２の音程、FM変調量、パルス幅 (…) を時間的に変化させることができます。

> m.env | モジュレーションエンベロープのオン/オフを決定します。
> A | モジュレーションエンベロープのアタックタイムを調整します。
> D | モジュレーションエンベロープのディケイタイムを調整します。
> amt | モジュレーションエンベロープの変化量を調整します。真中より右でプラスの変化量、左でマイナスの変化量、ちょうど真中の場合は変化量は０で時間的変化は発生しません。

Version history (Japanese), Ver1.05a:

> OSC2ピッチエンベロープをモジュレーションエンベロープとし、FM,p/wにも変調をかけれるようにした
> mod envの最大値が1になっていなかったのを修正   ("fixed that mod env's maximum value was not 1")

# Daichi synth programming article (synthprog/index.html)

Oscillator internals, no mod-env content. Relevant quotes (Shift-JIS decoded):

> Synth1では、ひとつのテーブルサイズは、2048サンプルだ(float型を使っているので、メモリサイズは、8KB)。
> …位相変数に固定小数点を使うと、テーブル読み出しでintへのキャストを使わなくてもよくなり…
> なお、整数部11bit、小数部21bitとすると… 今のところSynth1では、16bit:16bitを採用している。

FM is applied by adding to the phase increment:

```
osc1_phase = osc1_phase + osc1_delta + _FLOAT2INT(osc2_out * fmAmount * 2048/2 * (1<<16));
osc1_phase = osc1_phase & (2048 * (1<<16) - 1);
```

No pitch table, no 2^x / exponential lookup, no pitch-modulation depth is described.

# Robert Heaton unofficial manual

> Toggles the modulation envelope (`m.env`). The modulation envelope is effectively an ADSR envelope with sustain locked to 0, so all you get to control is A and D. It is always retriggered with every key press, even in legato mode.
> Adjusts how much the envelope modulates its target. Setting it to 0 is equivalent to disabling the modulation envelope altogether.
> Sets the target parameter that the envelope will modulate. This target can be: `osc2`: oscillator 2 pitch / `FM`: oscillator 1 FM / `p/w`: both oscillators' pulse-widths

No numeric range given.

# Zoran Nikolic, "Synth1 v1.12 unofficial User Manual" (2011)

> 10 - osc mod env on/off  0 - 1 [default value 0]
> 0 - Off  Turn Off the effect of the Modulation Envelope. While this is the same as setting Modulation Envelope Amount to its central position, this method is simply quicker.
> 1 - On  This is a simple type of envelope only comprising Attack, Decay and Amount controls. Therefore, it is called an AD-envelope. In effect, the AD-envelope behaves like an ADSR-envelope with Sustain set to zero. … it will start over from "zero" each time you press a new key, regardless of which value it had when you released the key.

> 11 - osc mod env amount  0 - 127 ( -64 - +63) [default value 64]
> This is used to set to what degree the Modulation Envelope should affect the destination. This knob is bi-polar, that is, a zero amount is in the middle (twelve o'clock). Turning it left introduces a negative envelope and turning it right gives you a positive envelope. [0=64]

> 12 - osc mod env attack  0 - 127 [default value 0]
> This is used to set the time it takes for the envelope to reach its "full level" after you have pressed a key.

> 13 - osc mod env decay  0 - 127 [default value 0]
> When the attack phase is over, the envelope drops back to zero level. The decay knob is used to set how long this should take.

> 71 - osc mod dest [>=v1.05]  0 - 2 [default value 0]
> 0 - osc2  When this is selected, the Modulation Envelope changes the pitch of Oscillator 2. … - If Attack is set to zero, and you have a positive Amount setting, Oscillator 2 pitch will decay down to normal pitch as set with the decay knob. - If Amount instead is set to a negative value, the pitch will rise up to "normal". - If Attack and Decay are both used and you have a positive Amount setting, the sound will start at normal pitch when you press the key, rise and then "fall back".
> 1 - FM  … the Modulation Envelope is routed to the amount of FM modulation. … this parameter operates as a supplement to the FM amount setting in the Oscillator section.
> 2 - p/w  … the Modulation Envelope changes the Pulse Width of the waveform from the Oscillators.

Adjacent parameter for scale comparison:

> 2 - osc2 pitch  0 - 127 ( -60s - +60s) [default value 64]
> … The setting is in semitone steps. The range is from 5 octaves below Oscillator 1, to 5 octaves above Oscillator 1.

Parameter-ID history table confirms ID 13 was named "osc2 p.env decay" in v1.00-1.05 and renamed "osc mod env decay" from v1.06; ID 71 "osc mod env dest." appears from v1.05.

Also relevant (destination exclusion):

> Please note that the noise is not affected by LFOs, Modulation Envelope or e.g. Modulation Wheel, even when these have Oscillator 2 selected as modulation destination.
