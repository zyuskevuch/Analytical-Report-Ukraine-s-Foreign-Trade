 =====================================================
 1. НАЛАШТУВАННЯ DUCKDB
 =====================================================

SET memory_limit = '16GB';
SET threads = 4;
SET temp_directory = 'D:/duckdb_temp';
SET max_temp_directory_size = '30GB';


 =====================================================
 2. ЗАВАНТАЖЕННЯ ТА ПЕРВИННА ОБРОБКА
 =====================================================

CREATE OR REPLACE TABLE trade_final AS

WITH source_data AS (
    SELECT *
    FROM read_csv_auto(
        'D:/міжнародна торгівля++.csv',
        header = true,
        encoding = 'utf-8'
    )
    WHERE "Товар" <> 'Усього'
      AND "Значення cпостереження" IS NOT NULL
),

parsed_data AS (
    SELECT
        "Товар",

        TRY_CAST(
            regexp_extract("Товар", 'Група ([0-9]{2})', 1)
            AS INTEGER
        ) AS group_code,

        "Показник",
        "Періодичність",

        TRY_CAST(
            "Значення cпостереження" AS DOUBLE
        ) AS observation,

        TRY_CAST(
            substr("Період", 1, 4) AS INTEGER
        ) AS year_num,

        CASE
            WHEN "Періодичність" = 'Місячна'
                THEN TRY_CAST(substr("Період", 7, 2) AS INTEGER)
            WHEN "Періодичність" = 'Річна'
                THEN 12
        END AS month_num,

        "Масштабування"

    FROM source_data
),


-- =====================================================
-- 3. КЛАСИФІКАЦІЯ УКТ ЗЕД
-- =====================================================

classified_data AS (
    SELECT
        *,

        CASE
            WHEN group_code BETWEEN 1 AND 5
                THEN 'I. Тваринна продукція'
            WHEN group_code BETWEEN 6 AND 14
                THEN 'II. Рослинна продукція'
            WHEN group_code = 15
                THEN 'III. Жири та олії'
            WHEN group_code BETWEEN 16 AND 24
                THEN 'IV. Готові харчові продукти'
            WHEN group_code BETWEEN 25 AND 27
                THEN 'V. Мінеральні продукти'
            WHEN group_code BETWEEN 28 AND 38
                THEN 'VI. Хімічна продукція'
            WHEN group_code BETWEEN 39 AND 40
                THEN 'VII. Пластмаси та гума'
            WHEN group_code BETWEEN 41 AND 43
                THEN 'VIII. Шкіра та хутро'
            WHEN group_code BETWEEN 44 AND 46
                THEN 'IX. Деревина'
            WHEN group_code BETWEEN 47 AND 49
                THEN 'X. Папір та поліграфія'
            WHEN group_code BETWEEN 50 AND 63
                THEN 'XI. Текстиль'
            WHEN group_code BETWEEN 64 AND 67
                THEN 'XII. Взуття та аксесуари'
            WHEN group_code BETWEEN 68 AND 70
                THEN 'XIII. Камінь, кераміка та скло'
            WHEN group_code = 71
                THEN 'XIV. Дорогоцінні метали та каміння'
            WHEN group_code BETWEEN 72 AND 83
                THEN 'XV. Недорогоцінні метали'
            WHEN group_code BETWEEN 84 AND 85
                THEN 'XVI. Машини та обладнання'
            WHEN group_code BETWEEN 86 AND 89
                THEN 'XVII. Транспорт'
            WHEN group_code BETWEEN 90 AND 92
                THEN 'XVIII. Прилади та інструменти'
            WHEN group_code = 93
                THEN 'XIX. Зброя та боєприпаси'
            WHEN group_code BETWEEN 94 AND 96
                THEN 'XX. Різні промислові товари'
            WHEN group_code = 97
                THEN 'XXI. Мистецтво та антикваріат'
            WHEN group_code BETWEEN 98 AND 99
                THEN 'XXII. Спеціальні товари'
            ELSE 'Невизначено'
        END AS "Розділ УКТ ЗЕД"

    FROM parsed_data
),


-- =====================================================
-- 4. ФОРМУВАННЯ НАКОПИЧУВАЛЬНИХ ЗНАЧЕНЬ
-- =====================================================

monthly_data AS (
    SELECT
        "Товар",
        "Показник",
        year_num,
        month_num,
        "Розділ УКТ ЗЕД",

        observation *
        CASE
            WHEN "Масштабування" = 'Тисячі' THEN 1000
            WHEN "Масштабування" = 'Одиниці' THEN 1
            ELSE NULL
        END AS cumulative_value

    FROM classified_data
    WHERE "Періодичність" = 'Місячна'
),

annual_data AS (
    SELECT
        "Товар",
        "Показник",
        year_num,
        month_num,
        "Розділ УКТ ЗЕД",

        observation *
        CASE
            WHEN "Масштабування" = 'Тисячі' THEN 1000
            WHEN "Масштабування" = 'Одиниці' THEN 1
            ELSE NULL
        END AS cumulative_value

    FROM classified_data
    WHERE "Періодичність" = 'Річна'
),

anchors AS (
    SELECT * FROM monthly_data

    UNION ALL

    SELECT * FROM annual_data
),


-- =====================================================
-- 5. КАЛЕНДАР ДЛЯ ВІДНОВЛЕННЯ ПРОПУСКІВ
-- =====================================================

series_bounds AS (
    SELECT
        "Товар",
        "Показник",
        "Розділ УКТ ЗЕД",
        year_num,
        MAX(month_num) AS max_month

    FROM classified_data

    GROUP BY
        "Товар",
        "Показник",
        "Розділ УКТ ЗЕД",
        year_num
),

calendar AS (
    SELECT
        b."Товар",
        b."Показник",
        b."Розділ УКТ ЗЕД",
        b.year_num,
        m.month_num,

        MAKE_DATE(
            b.year_num,
            m.month_num,
            1
        ) AS "Дата"

    FROM series_bounds b

    CROSS JOIN LATERAL
        range(1, b.max_month + 1) AS m(month_num)
),


-- =====================================================
-- 6. ЛІНІЙНА ІНТЕРПОЛЯЦІЯ НАКОПИЧУВАЛЬНИХ ДАНИХ
-- =====================================================

interpolated AS (
    SELECT
        c."Товар",
        c."Показник",
        c."Розділ УКТ ЗЕД",
        c.year_num,
        c.month_num,
        c."Дата",

        p.cumulative_value AS previous_value,
        n.cumulative_value AS next_value,

        p.anchor_month AS previous_month,
        n.anchor_month AS next_month,

        CASE
            WHEN p.cumulative_value IS NULL
              OR n.cumulative_value IS NULL
                THEN NULL

            WHEN p.anchor_month = n.anchor_month
                THEN p.cumulative_value

            ELSE
                p.cumulative_value
                +
                (
                    (n.cumulative_value - p.cumulative_value)
                    *
                    (c.month_num - p.anchor_month)
                    /
                    (n.anchor_month - p.anchor_month)
                )
        END AS cumulative_value

    FROM calendar c

    LEFT JOIN LATERAL (
        SELECT
            a.cumulative_value,
            a.month_num AS anchor_month

        FROM anchors a

        WHERE a."Товар" = c."Товар"
          AND a."Показник" = c."Показник"
          AND a.year_num = c.year_num
          AND a.month_num <= c.month_num

        ORDER BY a.month_num DESC
        LIMIT 1

    ) p ON TRUE

    LEFT JOIN LATERAL (
        SELECT
            a.cumulative_value,
            a.month_num AS anchor_month

        FROM anchors a

        WHERE a."Товар" = c."Товар"
          AND a."Показник" = c."Показник"
          AND a.year_num = c.year_num
          AND a.month_num >= c.month_num

        ORDER BY a.month_num ASC
        LIMIT 1

    ) n ON TRUE
),


-- =====================================================
-- 7. РОЗРАХУНОК ФАКТИЧНИХ ЩОМІСЯЧНИХ ЗНАЧЕНЬ
-- =====================================================

monthly_calculation AS (
    SELECT
        *,

        LAG(cumulative_value) OVER (
            PARTITION BY "Товар", "Показник", year_num
            ORDER BY month_num
        ) AS previous_cumulative

    FROM interpolated
),

final_data AS (
    SELECT
        "Дата",
        "Товар",
        "Показник",
        "Розділ УКТ ЗЕД",

        CASE
            WHEN month_num = 1
                THEN cumulative_value

            ELSE cumulative_value - previous_cumulative
        END AS monthly_value

    FROM monthly_calculation

    WHERE cumulative_value IS NOT NULL
)

-- =====================================================
-- 8. ФІНАЛЬНА ТАБЛИЦЯ
-- =====================================================

SELECT
    "Дата",
    "Товар",
    "Розділ УКТ ЗЕД",
    "Показник",

    ROUND(monthly_value, 2) AS "Значення"

FROM final_data

WHERE monthly_value IS NOT NULL

ORDER BY
    "Дата",
    "Показник",
    "Товар";
SELECT*
FROM trade_final
WHERE YEAR(Дата) = 2016
ORDER BY
    Дата,
    Показник;