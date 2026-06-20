# Clean-IP pool (per-carrier) · استخر آی‌پی تمیز (هر اپراتور)

*English first · فارسی در ادامه*

---

## 🇬🇧 English — consumed by Nova Panel "Smart (per-ISP)" mode

Nova Radar (https://github.com/IRNova/NovaRadar) writes its scan results here, **one file per
Iranian carrier**. The panel, when its Smart IP source points at this folder, automatically serves
each user the file that matches their operator.

### Files the panel looks for (in this order, per user)
1. `<carrier>.txt` — the user's exact operator (see codes below)
2. `ir.txt`        — generic Iran fallback (any IR user whose carrier file is missing)
3. `all.txt`       — combined fallback (everyone)

The panel tries them top-down and uses the first that has IPs, so you don't need every file —
even just `all.txt` works. Add carrier files to get per-operator tuning.

### Carrier codes (filename → operator)
| File           | Operator                         | ASN(s) |
|----------------|----------------------------------|--------|
| `mci.txt`      | Hamrah-e-Avval / MCI (mobile)    | 197207 |
| `mtn.txt`      | MTN Irancell (mobile)            | 44244  |
| `rightel.txt`  | Rightel (mobile)                 | 57218  |
| `shatel.txt`   | Shatel (fixed)                   | 31549  |
| `tci.txt`      | TCI / Mokhaberat (fixed)         | 58224  |
| `itc.txt`      | ITC (fixed)                      | 12880  |
| `ir.txt`       | generic Iran fallback            | —      |
| `all.txt`      | combined fallback                | —      |

### File format
Plain text, one entry per line — exactly Nova Radar's "Save to .txt" export:
```
104.18.42.137:443
[2606:4700::6812:2a89]:2053
141.101.90.11:8443#optional-remark
```
`ip:port` per line; an optional `#remark` after the IP is shown to the user as the node label.
Port defaults to 443 if omitted. IPv6 must be in [brackets]. CSV (incl. XIU2 Chinese headers) and
base64 sub links also work, but the plain list above is simplest.

### How to update (the loop your friend in Iran runs)
1. Open **Nova Radar**, pick the source(s), scan, let it verify (TCP+TLS) and sort by latency.
2. **Save to .txt** (or Copy).
3. Commit the file here under the right carrier name, e.g. `clean-ip/mci.txt`.
   (GitHub web: open `clean-ip/mci.txt` → ✏️ edit → paste → Commit. Or upload the file.)
4. Done. The panel re-pulls within its sub-update interval (default a few hours); users get the new
   IPs on their next subscription refresh. No panel redeploy, no per-user action.

---

## 🇮🇷 فارسی — مصرف‌شده توسط حالت «هوشمند (هر اپراتور)» پنل Nova

برنامهٔ Nova Radar (https://github.com/IRNova/NovaRadar) نتایج اسکنش را اینجا می‌نویسد، **برای هر
اپراتور ایرانی یک فایل**. وقتی منبع آی‌پی هوشمند پنل به این پوشه اشاره کند، پنل به‌طور خودکار به هر
کاربر فایلی را می‌دهد که با اپراتورش می‌خواند.

### فایل‌هایی که پنل می‌گردد (به این ترتیب، برای هر کاربر)
۱. `<اپراتور>.txt` — اپراتور دقیق کاربر (کدها پایین)
۲. `ir.txt`        — جایگزین عمومی ایران (هر کاربر ایرانی که فایل اپراتورش نباشد)
۳. `all.txt`       — جایگزین ترکیبی (همه)

پنل از بالا به پایین امتحان می‌کند و اولین فایلی که آی‌پی داشته باشد را استفاده می‌کند، پس همهٔ
فایل‌ها لازم نیستند — حتی فقط `all.txt` کار می‌کند. فایل‌های اپراتور را اضافه کن تا تنظیم دقیق هر
اپراتور را داشته باشی.

### کدهای اپراتور (نام فایل → اپراتور)
| فایل           | اپراتور                          | ASN    |
|----------------|----------------------------------|--------|
| `mci.txt`      | همراه اول / MCI (موبایل)         | 197207 |
| `mtn.txt`      | ایرانسل (موبایل)                 | 44244  |
| `rightel.txt`  | رایتل (موبایل)                   | 57218  |
| `shatel.txt`   | شاتل (ثابت)                      | 31549  |
| `tci.txt`      | مخابرات / TCI (ثابت)             | 58224  |
| `itc.txt`      | ITC (ثابت)                       | 12880  |
| `ir.txt`       | جایگزین عمومی ایران              | —      |
| `all.txt`      | جایگزین ترکیبی                   | —      |

### فرمت فایل
متن ساده، هر خط یک ورودی — دقیقاً همان خروجی «ذخیره در .txt» در Nova Radar:
```
104.18.42.137:443
[2606:4700::6812:2a89]:2053
141.101.90.11:8443#برچسب-دلخواه
```
هر خط `ip:port`؛ یک `#برچسب` اختیاری بعد از آی‌پی به‌عنوان نام نود به کاربر نشان داده می‌شود. اگر
پورت را ننویسی `443` فرض می‌شود. IPv6 باید داخل [کروشه] باشد. CSV (از جمله هدر چینی XIU2) و لینک‌های
sub با base64 هم کار می‌کنند، ولی لیست سادهٔ بالا آسان‌تر است.

### چطور به‌روزرسانی کنیم (حلقه‌ای که دوستت در ایران اجرا می‌کند)
۱. **Nova Radar** را باز کن، منبع(ها) را انتخاب کن، اسکن کن، بگذار تأیید (TCP+TLS) و بر اساس تأخیر
   مرتب کند.
۲. **ذخیره در .txt** (یا کپی).
۳. فایل را اینجا با نام اپراتور درست commit کن، مثلاً `clean-ip/mci.txt`.
   (وب گیت‌هاب: `clean-ip/mci.txt` را باز کن ← ✏️ ویرایش ← بچسبان ← Commit. یا فایل را آپلود کن.)
۴. تمام. پنل ظرف بازهٔ به‌روزرسانی اشتراک (پیش‌فرض چند ساعت) دوباره می‌خواند؛ کاربران در رفرش بعدیِ
   اشتراکشان آی‌پی‌های تازه را می‌گیرند. بدون دیپلوی مجدد پنل، بدون کار دستی برای هر کاربر.
