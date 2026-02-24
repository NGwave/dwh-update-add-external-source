-- DDL таблицы инкрементальных загрузок
DROP TABLE IF EXISTS dwh.load_dates_customer_report_datamart;

CREATE TABLE IF NOT EXISTS dwh.load_dates_customer_report_datamart (
    id BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL,
    load_dttm DATE NOT NULL,
    CONSTRAINT load_dates_customer_report_datamart_pk PRIMARY KEY (id)
);

WITH
dwh_delta AS ( -- определяем, какие данные были изменены в витрине или добавлены в DWH. Формируем дельту изменений
    SELECT     
            dcs.customer_id AS customer_id,
            dcs.customer_name AS customer_name,
            dcs.customer_address AS customer_address,
            dcs.customer_birthday AS customer_birthday,
            dcs.customer_email AS customer_email,
            fo.order_id AS order_id,
            dp.product_id AS product_id,
            dp.product_price AS product_price,
            dp.product_type AS product_type,
            fo.order_completion_date - fo.order_created_date AS diff_order_date, 
            fo.order_status AS order_status,
            TO_CHAR(fo.order_created_date, 'yyyy-mm') AS report_period,
            csrd.customer_id AS existing_customer_id,
            dc.load_dttm AS craftsman_load_dttm,
            dcs.load_dttm AS customers_load_dttm,
            dp.load_dttm AS products_load_dttm,
			dc.craftsman_id AS craftsman_id
            FROM dwh.f_order fo 
                INNER JOIN dwh.d_craftsman dc ON fo.craftsman_id = dc.craftsman_id 
                INNER JOIN dwh.d_customer dcs ON fo.customer_id = dcs.customer_id 
                INNER JOIN dwh.d_product dp ON fo.product_id = dp.product_id 
                LEFT JOIN dwh.customer_report_datamart csrd ON dcs.customer_id = csrd.customer_id
                    WHERE (fo.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_craftsman_report_datamart)) OR
                            (dc.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_craftsman_report_datamart)) OR
                            (dcs.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_craftsman_report_datamart)) OR
                            (dp.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_craftsman_report_datamart))
),
dwh_update_delta AS ( -- делаем выборку мастеров ручной работы, по которым были изменения в DWH. По этим мастерам данные в витрине нужно будет обновить
    SELECT     
            dd.existing_customer_id AS customer_id
            FROM dwh_delta dd 
                WHERE dd.existing_customer_id IS NOT NULL        
),
dwh_delta_insert_result AS ( -- делаем расчёт витрины по новым данным. 
    SELECT  T5.customer_id AS customer_id,
            T5.customer_name AS customer_name,
            T5.customer_address AS customer_address,
            T5.customer_birthday AS customer_birthday,
            T5.customer_email AS customer_email,
            T5.customer_money AS customer_money,
            T5.platform_money AS platform_money,
            T5.count_order AS count_order,
            T5.avg_order_price AS avg_price_order,
            T5.product_type AS top_product_category,
            T5.craftsman_id as top_craftsman_id,
            T5.median_time_order_completed AS median_time_order_completed,
            T5.count_order_created AS count_order_created,
            T5.count_order_in_progress AS count_order_in_progress,
            T5.count_order_delivery AS count_order_delivery,
            T5.count_order_done AS count_order_done,
            T5.count_order_not_done AS count_order_not_done,
            T5.report_period AS report_period 
            FROM (
                select	distinct on (craftsman_id)
                        *,
                        RANK() OVER(PARTITION BY T2.customer_id ORDER BY count_product DESC) AS rank_count_product 
                        FROM ( 
                            SELECT 
                                T1.customer_id AS customer_id,
                                T1.customer_name AS customer_name,
                                T1.customer_address AS customer_address,
                                T1.customer_birthday AS customer_birthday,
                                T1.customer_email AS customer_email,
                                SUM(T1.product_price) AS customer_money,
                                SUM(T1.product_price) * 0.1 AS platform_money,
                                COUNT(order_id) AS count_order,
                                AVG(T1.product_price) AS avg_order_price,
                                PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY diff_order_date) AS median_time_order_completed,
                                SUM(CASE WHEN T1.order_status = 'created' THEN 1 ELSE 0 END) AS count_order_created,
                                SUM(CASE WHEN T1.order_status = 'in progress' THEN 1 ELSE 0 END) AS count_order_in_progress, 
                                SUM(CASE WHEN T1.order_status = 'delivery' THEN 1 ELSE 0 END) AS count_order_delivery, 
                                SUM(CASE WHEN T1.order_status = 'done' THEN 1 ELSE 0 END) AS count_order_done, 
                                SUM(CASE WHEN T1.order_status != 'done' THEN 1 ELSE 0 END) AS count_order_not_done,
                                T1.report_period AS report_period
                                FROM dwh_delta AS T1
                                    WHERE T1.existing_customer_id IS NULL
                                        GROUP BY T1.customer_id, T1.customer_name, T1.customer_address, T1.customer_birthday, T1.customer_email, T1.report_period
                            ) AS T2 
								INNER JOIN (
									SELECT   -- самый популярный для каждого заказчика мастер
									customer_id AS customer_id_for_top_craftsman, 
                                    craftsman_id,
                                    COUNT(order_id) AS order_count
									FROM dwh_delta AS dd                              
										GROUP BY customer_id, craftsman_id
											ORDER BY craftsman_id, order_count DESC) AS T3 ON T2.customer_id = T3.customer_id_for_top_craftsman
                                INNER JOIN (
                                    SELECT     -- самая популярная категория товаров для заказчика 
                                            dd.customer_id AS customer_id_for_product_type, 
                                            dd.product_type, 
                                            COUNT(dd.product_id) AS count_product
                                            FROM dwh_delta AS dd
                                                GROUP BY dd.customer_id, dd.product_type
                                                    ORDER BY count_product DESC) AS T4 ON T2.customer_id = T4.customer_id_for_product_type
                ) AS T5 WHERE T5.rank_count_product = 1 ORDER BY report_period -- условие помогает оставить в выборке первую по популярности категорию товаров	
),
dwh_delta_update_result AS ( --обновляем существующие данные
SELECT  T5.customer_id AS customer_id,
            T5.customer_name AS customer_name,
            T5.customer_address AS customer_address,
            T5.customer_birthday AS customer_birthday,
            T5.customer_email AS customer_email,
            T5.customer_money AS customer_money,
            T5.platform_money AS platform_money,
            T5.count_order AS count_order,
            T5.avg_order_price AS avg_price_order,
            T5.product_type AS top_product_category,
            T5.craftsman_id as top_craftsman_id,
            T5.median_time_order_completed AS median_time_order_completed,
            T5.count_order_created AS count_order_created,
            T5.count_order_in_progress AS count_order_in_progress,
            T5.count_order_delivery AS count_order_delivery,
            T5.count_order_done AS count_order_done,
            T5.count_order_not_done AS count_order_not_done,
            T5.report_period AS report_period 
            FROM (
                select	distinct on (craftsman_id)
                        *,
                        RANK() OVER(PARTITION BY T2.customer_id ORDER BY count_product DESC) AS rank_count_product 
                        FROM ( 
                            SELECT 
                                T1.customer_id AS customer_id,
                                T1.customer_name AS customer_name,
                                T1.customer_address AS customer_address,
                                T1.customer_birthday AS customer_birthday,
                                T1.customer_email AS customer_email,
                                SUM(T1.product_price) AS customer_money,
                                SUM(T1.product_price) * 0.1 AS platform_money,
                                COUNT(order_id) AS count_order,
                                AVG(T1.product_price) AS avg_order_price,
                                PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY diff_order_date) AS median_time_order_completed,
                                SUM(CASE WHEN T1.order_status = 'created' THEN 1 ELSE 0 END) AS count_order_created,
                                SUM(CASE WHEN T1.order_status = 'in progress' THEN 1 ELSE 0 END) AS count_order_in_progress, 
                                SUM(CASE WHEN T1.order_status = 'delivery' THEN 1 ELSE 0 END) AS count_order_delivery, 
                                SUM(CASE WHEN T1.order_status = 'done' THEN 1 ELSE 0 END) AS count_order_done, 
                                SUM(CASE WHEN T1.order_status != 'done' THEN 1 ELSE 0 END) AS count_order_not_done,
                                T1.report_period AS report_period
                                FROM (		select 
											dcs.customer_id AS customer_id,
											dcs.customer_name AS customer_name,
											dcs.customer_address AS customer_address,
											dcs.customer_birthday AS customer_birthday,
											dcs.customer_email AS customer_email,
											fo.order_id AS order_id,
											dp.product_id AS product_id,
											dp.product_price AS product_price,
											dp.product_type AS product_type,
											fo.order_completion_date - fo.order_created_date AS diff_order_date, 
											fo.order_status AS order_status,
											TO_CHAR(fo.order_created_date, 'yyyy-mm') AS report_period
                                            FROM dwh.f_order fo 
                                                INNER JOIN dwh.d_craftsman dc ON fo.craftsman_id = dc.craftsman_id 
                                                INNER JOIN dwh.d_customer dcs ON fo.customer_id = dcs.customer_id 
                                                INNER JOIN dwh.d_product dp ON fo.product_id = dp.product_id
                                                INNER JOIN dwh_update_delta ud ON fo.customer_id = ud.customer_id
								) as T1
                                   GROUP BY T1.customer_id, T1.customer_name, T1.customer_address, T1.customer_birthday, T1.customer_email, T1.report_period
                            ) AS T2 
								INNER JOIN (
									SELECT   -- самый популярный для каждого заказчика мастер
									customer_id AS customer_id_for_top_craftsman, 
                                    craftsman_id,
                                    COUNT(order_id) AS order_count
									FROM dwh_delta AS dd                              
										GROUP BY customer_id, craftsman_id
											ORDER BY craftsman_id, order_count DESC) AS T3 ON T2.customer_id = T3.customer_id_for_top_craftsman
                                INNER JOIN (
                                    SELECT     -- самая популярная категория товаров для заказчика 
                                            dd.customer_id AS customer_id_for_product_type, 
                                            dd.product_type, 
                                            COUNT(dd.product_id) AS count_product
                                            FROM dwh_delta AS dd
                                                GROUP BY dd.customer_id, dd.product_type
                                                    ORDER BY count_product DESC) AS T4 ON T2.customer_id = T4.customer_id_for_product_type
                ) AS T5 WHERE T5.rank_count_product = 1 ORDER BY report_period -- условие помогает оставить в выборке первую по популярности категорию товаров	 -- делаем перерасчёт для существующих записей витринs, так как данные обновились за отчётные периоды. Логика похожа на insert, но нужно достать конкретные данные из DWH
),   
insert_delta AS ( -- выполняем insert новых расчитанных данных для витрины 
    INSERT INTO dwh.customer_report_datamart (
			customer_id,
            customer_name,
            customer_address,
            customer_birthday,
            customer_email,
            customer_money,
            platform_money,
            count_order,
            avg_price_order,
            top_product_category,
            top_craftsman_id,
            median_time_order_completed,
            count_order_created,
            count_order_in_progress,
            count_order_delivery,
            count_order_done,
            count_order_not_done,
            report_period 
    ) SELECT 
            customer_id,
            customer_name,
            customer_address,
            customer_birthday,
            customer_email,
            customer_money,
            platform_money,
            count_order,
            avg_price_order,
            top_product_category,
            top_craftsman_id,
            median_time_order_completed,
            count_order_created,
            count_order_in_progress,
            count_order_delivery,
            count_order_done,
            count_order_not_done,
            report_period 
            FROM dwh_delta_insert_result
),
update_delta AS ( -- выполняем обновление показателей в отчёте по уже существующим мастерам
    UPDATE dwh.craftsman_report_datamart SET
            customer_id = updates.customer_id,
            customer_name = updates.customer_name,
            customer_address = updates.customer_address,
            customer_birthday = updates.customer_birthday,
            customer_email = updates.customer_email,
            customer_money = updates.customer_money,
            platform_money = updates.platform_money,
            count_order = updates.count_order,
            avg_price_order = updates.avg_price_order,
            top_product_category = updates.top_product_category,
            top_craftsman_id = updates.top_craftsman_id,
            median_time_order_completed = updates.median_time_order_completed,
            count_order_created = updates.count_order_created,
            count_order_in_progress = updates.count_order_in_progress,
            count_order_delivery = updates.count_order_delivery,
            count_order_done = updates.count_order_done,
            count_order_not_done = updates.count_order_in_progress,
            report_period = updates.report_period
    FROM (
        SELECT 
           customer_id,
            customer_name,
            customer_address,
            customer_birthday,
            customer_email,
            customer_money,
            platform_money,
            count_order,
            avg_price_order,
            top_product_category,
            top_craftsman_id,
            median_time_order_completed,
            count_order_created,
            count_order_in_progress,
            count_order_delivery,
            count_order_done,
            count_order_not_done,
            report_period  
            FROM dwh_delta_update_result) AS updates
    WHERE dwh.craftsman_report_datamart.customer_id = updates.customer_id
),
insert_load_date AS ( -- делаем запись в таблицу загрузок о том, когда была совершена загрузка, чтобы в следующий раз взять данные, которые будут добавлены или изменены после этой даты
    INSERT INTO dwh.load_dates_customer_report_datamart (
        load_dttm
    )
    SELECT GREATEST(COALESCE(MAX(craftsman_load_dttm), NOW()), 
                    COALESCE(MAX(customers_load_dttm), NOW()), 
                    COALESCE(MAX(products_load_dttm), NOW())) 
        FROM dwh_delta
)
SELECT 'increment datamart'; -- инициализируем запрос CTE