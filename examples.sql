  --Stats about delivery times and transporters--

SELECT 
--Extract only the month number from the column date_purchase
EXTRACT(MONTH FROM date_purchase) AS month
--Change the priority name to add numbers in front so there's a possibility to order it
, CASE
  WHEN priority = 'High' THEN '1 - High'
  WHEN priority = 'Medium' THEN '2 - Medium'
  ELSE '3 - Low'
END AS priority
, transporter
--Average date difference in days between the purchase and delivery rounded to one decimal place
, ROUND(AVG(DATE_DIFF(date_delivery, date_purchase, DAY)),1) AS avg_delivery_time
-Shortest time for delivery
, MIN(DATE_DIFF(date_delivery, date_purchase, DAY)) AS shortest_time
-Longest time for delivery
, MAX(DATE_DIFF(date_delivery, date_purchase, DAY)) AS longest_time
-Column parcel_id is PK, count them to determine the total number of parcels
, COUNT(parcel_id) AS nb_parcels
-Sum column quantity to get total number of products
, SUM(qty) AS nb_products
--Divide number of products per total parcels to get products per parcel
, ROUND(SUM(qty)/COUNT(parcel_id),1) AS products_per_parcel
FROM `e-tensor-411113.course15.circle_parcel_ok`
JOIN `e-tensor-411113.course15.circle_parcel_product`
USING(parcel_id)
WHERE date_delivery IS NOT NULL
GROUP BY transporter, priority, month
ORDER BY month, priority, transporter

-------
  
  --Saving query over original table to delete duplicates--

--Create CTE to add a row number partitioned by customer_unique_id
WITH
  rn_delete AS (
  SELECT
    *,
    ROW_NUMBER() OVER(PARTITION BY customer_unique_id) AS rn_number
  FROM
    `e-tensor-411113.Olist.olist_customers`)
SELECT
  customer_id,
  customer_unique_id,
  customer_zip_code_prefix,
  customer_city,
  customer_state
FROM
  rn_delete
--Filter only results where row number is equal to 1, which eliminates all duplicates that will have the same customer_unique_id
WHERE
  rn_number = 1

-------

  --Retention check for joins--
  
--By filtering orders_id for null values, you only get results from table B (ship)

SELECT *
FROM `e-tensor-411113.course16.gwz_orders_operational` AS orders_op
RIGHT JOIN `e-tensor-411113.course16.gwz_ship` AS ship
ON orders_op.orders_id = ship.orders_id
WHERE orders_op.orders_id IS NULL

-------

  --Create CTE to calculate total turnover and total promotion value offered, both rounded to 2 decimal places

WITH margin_metrics AS(
  SELECT
  orders_id
  , products_id
  , promo_name
  , ROUND(SUM(turnover),2) AS turnover
  , ROUND(SUM(turnover_before_promo)-SUM(turnover),2) AS promo_value
  FROM `e-tensor-411113.course17.gwz_sales_17`
  GROUP BY orders_id, products_id, promo_name
)
SELECT orders_id
, products_id
, turnover
, promo_name
, promo_value
--Safe divide to guarantee it won't break in case turnover is 0. Calculate promo percentage by dividing promotion value over turnover
, ROUND(SAFE_DIVIDE(promo_value, turnover),2) AS promo_percent
--Case to categorize types of promotions
, CASE
--Selecting any promo_name that contain the caracters "dlc" somewhere in them with a LOWER to make sure it's uniform
    WHEN LOWER(promo_name) LIKE '%dlc%' then 'short-lived'
--Divide promo options into low and high depending on the promo percentage each product had. 
--Under 10% for low promotions, above 30% for high promotions as long as it doesn't contain "dlc" in its promo_name
    WHEN ROUND(SAFE_DIVIDE(promo_value, turnover),2) < 0.1 then 'Low Promo'
    WHEN ROUND(SAFE_DIVIDE(promo_value, turnover),2) >= 0.30 AND NOT LOWER(promo_name) LIKE '%dlc%' then 'High Promo'
    ELSE 'Medium Promo'
END AS promo_type
FROM margin_metrics

-------

  -- Creating functions for margin percent and promotion percent and then calling them in a query

--Parameters are turnover and purchase_cost as floats
CREATE FUNCTION course17.margin_percent (turnover FLOAT64, purchase_cost FLOAT64) AS (
    ROUND((turnover-purchase_cost)/ turnover,3)*100
   );

--Parameters are turnover and turnover_before_promo as floats
  CREATE FUNCTION course17.promo_percent (turnover FLOAT64, turnover_before_promo FLOAT64) AS (
    ROUND((turnover_before_promo - turnover) / (turnover_before_promo),2)*100
   );

   SELECT
     date_date
     ,orders_id
     ,products_id
     ,promo_name
     ,turnover_before_promo
     ,turnover
     ,purchase_cost
     
--Calling the functions and inputting what data I'll use as parameters
     ,course17.margin_percent(turnover, purchase_cost) AS margin_percent
     ,course17.promo_percent (turnover, turnover_before_promo) AS promo_percent
   FROM `course17.gwz_sales_17`;

-------

  -- KPI Funnel statistics

-- Create CTE to make create all definitions and calculate the time it takes between stages
WITH funnel_times AS(
  SELECT *
,CASE
  -- date_lead -> date_opportunity -> date_customer | date_lost
  -- if the lead has become a customer and was not lost
  WHEN date_lost IS NOT NULL THEN 0
  WHEN date_customer IS NOT NULL THEN 1
  ELSE NULL
END AS lead2customer
,CASE
  -- if the lead has become an opportunity and was not lost
  WHEN date_lost IS NOT NULL THEN 0
  WHEN date_opportunity IS NOT NULL THEN 1
  ELSE NULL
END AS lead2opportunity
,CASE
  -- if the opportunity became a customer and was not lost and isn't just an opportunity anymore
  WHEN date_lost IS NOT NULL AND date_opportunity IS NOT NULL THEN 0
  WHEN date_customer IS NOT NULL THEN 1
  ELSE NULL
END AS opportunity2customer
, DATE_DIFF(date_customer, date_lead, DAY) AS lead2customer_time
, DATE_DIFF(date_opportunity, date_lead, DAY) AS lead2opportunity_time
, DATE_DIFF(date_customer, date_opportunity, DAY) AS opportunity2customer_time
FROM `e-tensor-411113.course15.cc_funnel_kpi`)

SELECT 
  -- extract the month from lead date to have a reference in a different granularity, comparing results between months
  EXTRACT(MONTH FROM date_lead) AS month_lead
, COUNT(*) AS nb_prospects
, COUNT(date_customer) AS nb_customers
-- rates
  -- By adding all lead2customers, I'm counting the amount of customers I have. If I average that value I'll divide by total leads, which gives me a rate of conversion. Same applies to other stages.
, ROUND(AVG(lead2customer)*100,1) AS lead2customer_rate
, ROUND(AVG(lead2opportunity)*100,1) AS lead2opportunity_rate
, ROUND(AVG(opportunity2customer)*100,1) AS opportunity2customer_rate
-- times
, ROUND(AVG(lead2customer_time),2) AS lead2customer_time
, ROUND(AVG(lead2opportunity_time),2) AS lead2opportunity_time
, ROUND(AVG(opportunity2customer_time),2) AS opportunity2customer_time
FROM funnel_times
-- to be able to do aggregations
GROUP BY month_lead
-- to see the results by ascending order for months
ORDER BY month_lead

-------

  -- Check if payment entries are repeated  

WITH
  rn_delete AS (
  SELECT
    *,
  -- row per order_id
    ROW_NUMBER() OVER(PARTITION BY order_id) AS rn_number
  -- total payment per order_id
    , SUM(payment_value) OVER(PARTITION BY order_id) AS total_pay
  FROM
    `e-tensor-411113.Olist.olist_order_payments`)
SELECT
  order_id,
  payment_sequential,
  payment_type,
  payment_installments,
  payment_value,
  rn_number,
  total_pay
FROM
  rn_delete
  -- Since there can be more than one payment per order_id, you also need to check if the payment_value is equal to total_pay. If it isn't, it's just an installment, if it is, the entry is repeated.
WHERE rn_number = 2 AND payment_value = total_pay
ORDER BY order_id
