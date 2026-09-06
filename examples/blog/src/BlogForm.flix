///
/// HTTP の境界の見本。フォームの全項目を検証してから registerUser を呼び、検証のエラーと制約違反の翻訳を同じ型で返す。
/// 検証は Flix 標準の Validation で全項目を集める（forM は最初の失敗で止まる）。ライブラリはこの層を持たない。
///
mod BlogForm {

    use Blog.NewUser
    use Blog.RegisterErr

    ///
    /// フォームの入力。検証前なので全部 String。
    ///
    pub type alias RegisterForm = { name = String, email = String }

    ///
    /// フォームに返すエラー。検証で見つかる物と、DB の制約違反から翻訳した物を同じ型にまとめる。
    ///
    pub enum FormError with Eq, Order, ToString {
        /// name が 50 文字を超えている（DDL の users_name_length と同じ規則）
        case NameTooLong
        /// email の形式ではない
        case EmailInvalid
        /// その email は登録済み（DB の users_email_key）
        case EmailTaken(String)
    }

    ///
    /// フォームを検証して NewUser にする。全項目の失敗を集める。
    /// 言語側の検証は UX のための重複で、防御線は DDL の CHECK。
    ///
    pub def validate(form: RegisterForm): Validation[FormError, NewUser] =
        forA (
            name <- validName(form#name);
            email <- validEmail(form#email)
        ) yield { name = name, email = email }

    // WhyNot: String.length（UTF-16 単位）と PG の length()（文字数）はサロゲートペアでずれる。UX 用の重複なので DB 側を正とし、ここでは揃えない
    def validName(raw: String): Validation[FormError, String] =
        if (String.length(raw) <= 50) Validation.success(raw) else Validation.failure(FormError.NameTooLong)

    def validEmail(raw: String): Validation[FormError, String] =
        if (String.contains(substr = "@", raw)) Validation.success(raw) else Validation.failure(FormError.EmailInvalid)

    ///
    /// 境界。検証 → 登録 → 制約違反の翻訳を 1 つの Result にする。DbErr は上へ流す。
    ///
    pub def register(form: RegisterForm): Result[List[FormError], Int64] \ DbWrite =
        match Validation.toResult(validate(form)) {
            case Err(errors) => Err(Nec.toList(errors))
            case Ok(user) =>
                run {
                    Ok(Blog.registerUser(user))
                } with handler RegisterErr {
                    def emailTaken(email, _resume) = Err(List#{FormError.EmailTaken(email)})
                    def nameTooLong(_resume) = Err(List#{FormError.NameTooLong})
                }
        }

}
