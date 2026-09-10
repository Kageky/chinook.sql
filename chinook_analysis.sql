-- ============================================================
-- Пет-проект: анализ продаж цифрового музыкального магазина (Chinook)
-- SQL-часть (PostgreSQL). Автор: Антон Харламов
-- Цель проекта: практика CTE, сложных подзапросов и оконных функций
-- на реальных бизнес-вопросах.
-- Таблицы: customer, invoice, invoice_line, track, genre, employee
-- ============================================================


-- 1. ТОП-3 ТРЕКА ПО ВЫРУЧКЕ В КАЖДОМ ЖАНРЕ
-- Business-вопрос: какие треки лучше всего продаются внутри каждого
-- жанра?
-- Вариант через подзапрос в FROM:
SELECT sub.track_id, sub.name, sub.genre_id, sub.viruchka, sub.rn
FROM (
    SELECT t.track_id, t.name, t.genre_id,
        sum(il.unit_price * il.quantity) AS viruchka,
        row_number() OVER (PARTITION BY t.genre_id
                            ORDER BY sum(il.unit_price * il.quantity) DESC) AS rn
    FROM track t
    INNER JOIN genre g ON t.genre_id = g.genre_id
    INNER JOIN invoice_line il ON il.track_id = t.track_id
    GROUP BY t.track_id, t.name
) AS sub
WHERE sub.rn <= 3;

-- Тот же результат через CTE (эквивалентно, другой синтаксис):
WITH sub AS (
    SELECT t.track_id, t.name, t.genre_id,
        sum(il.unit_price * il.quantity) AS viruchka,
        row_number() OVER (PARTITION BY t.genre_id
                            ORDER BY sum(il.unit_price * il.quantity) DESC) AS rn
    FROM track t
    INNER JOIN genre g ON t.genre_id = g.genre_id
    INNER JOIN invoice_line il ON il.track_id = t.track_id
    GROUP BY t.track_id, t.name
)
SELECT track_id, name, genre_id, viruchka, rn
FROM sub
WHERE rn <= 3;


-- 2. ДИНАМИКА ВЫРУЧКИ ПО МЕСЯЦАМ: НАКОПИТЕЛЬНЫЙ ИТОГ И MoM
-- Business-вопрос: как меняется выручка от месяца к месяцу и какая
-- накопленная выручка на любой момент времени?
WITH monthly AS (
    SELECT extract(year FROM invoice_date) AS year,
        extract(month FROM invoice_date) AS month,
        sum(il.quantity * il.unit_price) AS viruchka
    FROM invoice i
    INNER JOIN invoice_line il ON i.invoice_id = il.invoice_id
    GROUP BY extract(year FROM invoice_date), extract(month FROM invoice_date)
),
monthly_with_lag AS (
    SELECT year, month, viruchka,
        sum(viruchka) OVER (ORDER BY year, month) AS running_total,
        lag(viruchka) OVER (ORDER BY year, month) AS prev_month
    FROM monthly
    ORDER BY year, month
)
SELECT year, month, viruchka, running_total,
    (viruchka - prev_month) / prev_month * 100 AS mom
FROM monthly_with_lag;
-- НАХОДКА (проверено на реальность, не баг в запросе): в нескольких
-- месяцах MoM выходит ровно 0% — выручка совпадает до копейки.
-- Проверка вручную показала, что количество счетов в этих месяцах
-- одинаковое (~7), а суммы отдельных счетов повторяются одним и тем
-- же циклом: 1.98, 1.98, 3.96, 5.94, 8.91, 13.86, 0.99 (сумма 37.62
-- разных месяцах). Это особенность синтетических тестовых данных
-- Chinook, а не ошибка в GROUP BY/JOIN — подтверждено сверкой на
-- уровне отдельных invoice.


-- 3. КЛИЕНТЫ С ТРАТАМИ ВЫШЕ СРЕДНЕГО — ДВА РАЗНЫХ ВОПРОСА
-- Business-вопрос можно понять двумя способами — по отдельным
-- счетам или по клиенту в среднем, — и это разная логика запроса.

-- 3a. Клиенты, у которых ЕСТЬ хотя бы один счёт выше среднего чека
-- по всей базе (сравнение отдельных счетов):
SELECT DISTINCT c.customer_id
FROM customer c
INNER JOIN invoice i ON i.customer_id = c.customer_id
WHERE i.total > (
    SELECT avg(total) AS avg_total
    FROM invoice
);

-- 3b. Клиенты, у которых СРЕДНИЙ чек (среднее по всем ИХ счетам)
-- выше среднего чека по всей базе — подзапрос в FROM + подзапрос
-- в WHERE:
SELECT virt.customer_id, virt.avg_total_4each_client,
    (SELECT avg(total) FROM invoice) AS avg_for_all
FROM (
    SELECT c.customer_id, avg(total) AS avg_total_4each_client
    FROM customer c
    INNER JOIN invoice i ON i.customer_id = c.customer_id
    GROUP BY c.customer_id
) AS virt
WHERE virt.avg_total_4each_client > (
    SELECT avg(total) FROM invoice
);
-- Примечание по выбору инструмента: пробовал переписать через 3 CTE,
-- чтобы не повторять скалярный подзапрос avg(total) дважды —
-- получилось избыточно сложно для такой простой агрегации. Вывод:
-- CTE оправдан, когда переиспользуемый кусок — это дорогой
-- JOIN+GROUP BY (как в разделе 3 ниже), а не тривиальный AVG() по
-- маленькой таблице.


-- 4. ВЫРУЧКА ПО СОТРУДНИКАМ ЧЕРЕЗ ИХ КЛИЕНТОВ
-- Business-вопрос: кто из сотрудников (менеджеров по работе с
-- клиентами) принёс больше всего денег через закреплённых за ним
-- клиентов?
SELECT e.employee_id, e.first_name, sum(i.total) AS viruchka
FROM employee e
INNER JOIN customer c ON c.support_rep_id = e.employee_id
INNER JOIN invoice i ON i.customer_id = c.customer_id
GROUP BY e.employee_id, e.first_name
ORDER BY sum(i.total) DESC;
-- БАГ (найден и исправлен): первая версия джойнила
-- c.support_rep_id = e.reports_to — это поле руководителя самого
-- сотрудника, а не идентификатор самого сотрудника, поэтому запрос
-- не возвращал ничего. Исправлено на c.support_rep_id = e.employee_id.
-- Результат: только 3 сотрудника (Sales Support Agent) имеют
-- закреплённых клиентов — Jane 833.04, Margaret 775.40, Steve 720.16.


-- 5. КЛИЕНТЫ БЕЗ ПОКУПОК КОНКРЕТНОГО ЖАНРА (сегмент для рассылки)
-- Business-вопрос: кому предложить конкретный жанр в рекомендациях/
-- рассылке, потому что они его ни разу не покупали?
SELECT customer_id
FROM customer
WHERE customer_id NOT IN (
    SELECT c.customer_id
    FROM customer c
    INNER JOIN invoice i ON c.customer_id = i.customer_id
    INNER JOIN invoice_line il ON il.invoice_id = i.invoice_id
    INNER JOIN track t ON t.track_id = il.track_id
    INNER JOIN genre g ON g.genre_id = t.genre_id
    WHERE g.name = 'Bossa Nova'
);
-- Находка: с жанром Rock результат пустой — из 59 клиентов ВСЕ
-- хоть раз покупали Rock (самый популярный жанр в базе), поэтому
-- для него сегмент не имеет смысла. С менее популярным жанром
-- Bossa Nova результат содержательный: 52 из 59 клиентов ни разу
-- не покупали Bossa Nova — целевая аудитория для рекомендации.


-- 6. КЛИЕНТЫ БЕЗ ЕДИНОЙ ПОКУПКИ (проверка базы на "мёртвые" аккаунты)
SELECT c.customer_id
FROM customer c
LEFT JOIN invoice i ON c.customer_id = i.customer_id
WHERE i.invoice_id IS NULL;
-- Результат: 0 строк — в базе нет клиентов без покупок (в Chinook
-- каждому клиенту изначально создан хотя бы один счёт).


-- 7. ЧАСТЫЕ, НО НЕКРУПНЫЕ КЛИЕНТЫ (GROUP BY + HAVING)
-- Business-вопрос: кто покупает часто (>5 счетов), но по мелочи
-- (средний чек ниже общего среднего) — потенциальный сегмент для
-- допродаж на более дорогие позиции.
SELECT customer_id,
    count(*) AS invoice_count,
    avg(total) AS avg_check
FROM invoice
GROUP BY customer_id
HAVING count(*) > 5
   AND avg(total) < (SELECT avg(total) FROM invoice);
-- Результат: 36 из 59 клиентов подходят под условие — но при
-- ближайшем рассмотрении почти все они имеют практически одинаковый
-- avg_check (5.37 или 5.52), что снова указывает на тот же
-- повторяющийся цикл сумм в тестовых данных (см. находку в разделе
-- 2), а не на реальное поведенческое различие между клиентами.
