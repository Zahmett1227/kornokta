# ADR-004 — Annotation grounding ve tek-çağrılık fotoğraf onayı

**Durum:** Kabul edildi (2026-08-04)

## Bağlam

Faz 2'de işaret seçimi `[lineId]` olarak taşınıyordu. Bu şekil, işaretin
görüntüdeki kanıtını (tür, bbox, güven) kaybediyor; kısa bir alt çizgiyi tüm
satıra dönüştürüyor; eş metinli uzak bölgeleri ayırt edemiyor ve onay ekranında
OCR'ın tekrar çalışmasına yol açabiliyordu. Kart üretimi öncesinde seçimin
metinsel değil, görsel olarak ground edilmiş olması gerekir.

## Karar

1. İstemci `AnnotationEvidence` üretir: işaret türü, normalize görüntü bbox'ı,
   Vision token/satır kimlikleri, karar/güven ve ölçümler. `AnnotationGroup`
   bunun üstünde bağımsız bilgi birimidir; seçili token, bağlam, üst başlık,
   düzen türü ve el yazısı ilişkisini taşır.
2. Vision yalnız geometri/yerel işaret ölçümü sağlar. Birincil metin ve token
   geometri Google Document AI'den gelir; grounding id eşitliğiyle değil bbox
   örtüşmesi ve token üyeliğiyle yapılır.
3. Google OCR sayfa başına bir kez çağrılır. Sonuç, seçim ve kullanıcı-onay
   durumu `OCRSnapshot` olarak yalnız cihazda saklanır. Belirsiz veya quick
   confirm onayı sayfa fotoğrafında overlay ile verilir; onaydan sonra aynı
   snapshot devam eder, Vision/Google yeniden çağrılmaz. Kullanıcı overlay
   kutularını dokunarak ekleyip çıkarabilir; "Manuel alan ekle" ile çizilen
   bir dikdörtgen de sonraki aşamada aynı snapshot tokenlarına ground edilir.
4. Her grup bağımsız `TextRegion`, `KnowledgeUnit`, kart seti ve gerçek kaynak
   kırpması üretir. Aynı yazı farklı bbox'taysa veya sütunlardaysa birleşmez.
5. Document AI'nin token stil çıktısı, yalnız merkezi
   `DOCUMENTAI_COMPUTE_STYLE_INFO=true` ayarında istenir. Varsayılan kapalıdır:
   Enterprise OCR sürümünün desteklediği ve maliyetinin kabul edildiği ayrıca
   doğrulanmalıdır.
6. Yerel annotation metadata'sı mevcut `/api/cards` isteğine otomatik
   eklenmez. OCR türevi konum, el yazısı ve ilişkisel veriyi yeni bir dış
   sözleşmeye göndermek için kullanıcıdan açık onay gerekir.

## Sonuçlar

- Onay ekranı kullanıcıya gerçek fotoğraf üzerinde neyin seçildiğini gösterir;
  erişilebilir metin özeti yalnız yardımcı açıklamadır.
- Kısa işaretler ve çoklu bölgeler daha doğru kalır; kart üretimi grup başına
  yapılır.
- Snapshot JSON'ı ve kaynak kırpmaları cihaz deposunda yer kaplar; başarılı
  üretimden sonra geçici snapshot silinir.
- Bu karar 20 görüntülük altın set veya gerçek karmaşık fotoğraf kabul testinin
  yerine geçmez. Fixture kullanıcı tarafından yerleştirilmelidir; telifli
  görüntü depoya eklenmez.
