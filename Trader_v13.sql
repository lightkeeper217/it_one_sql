DROP SCHEMA IF EXISTS lkp_trader CASCADE;
CREATE SCHEMA lkp_trader;
DROP PROCEDURE IF EXISTS initialize_world;
DROP PROCEDURE IF EXISTS think;

CREATE TABLE lkp_trader.PathsTime(
	"id" SERIAL PRIMARY KEY NOT NULL,
	"ship" INTEGER NOT NULL,
	"island_from" INTEGER NOT NULL,
	"island_to" INTEGER NOT NULL,
	"distance"  DOUBLE PRECISION
);

CREATE INDEX ON lkp_trader.PathsTime (ship, island_from); 

CREATE TABLE lkp_trader.tasks(
	"offer" INTEGER PRIMARY KEY NOT NULL, 
	"ship" INTEGER,
	"item" INTEGER NOT NULL,
	"capacity" DOUBLE PRECISION,
	"expected" DOUBLE PRECISION,
	"customer" INTEGER NOT NULL,
	"island_from" INTEGER,
	"island_to" INTEGER
);

CREATE PROCEDURE initialize_world(player_id INTEGER) AS $$
DECLARE 
	_distance_x DOUBLE PRECISION;
	_distance_y DOUBLE PRECISION;
	_x1 DOUBLE PRECISION;
	_x2 DOUBLE PRECISION;
	_y1 DOUBLE PRECISION;
	_y2 DOUBLE PRECISION;
	_island_from INTEGER;
	_island_to INTEGER;
	_ship INTEGER;
	_speed DOUBLE PRECISION;
	_map_size DOUBLE PRECISION;
BEGIN
	SELECT world.global.map_size INTO _map_size FROM world.global;
	FOR _island_to, _island_from, _x1, _x2, _y1, _y2, _speed, _ship IN
		SELECT island_to.id, island_from.id, island_to.x, island_from.x, island_to.y, island_from.y, ships.speed, ships.id
		FROM world.islands AS island_to
		JOIN world.islands AS island_from
		ON island_to.id <> island_from.id
		JOIN world.ships ON ships.player = player_id
		ORDER BY world.ships.id, island_to.id
	LOOP
		IF _x1 > _x2 THEN
			_distance_x = LEAST(_x1 - _x2, _x2 + _map_size - _x1);
		ELSE
			_distance_x = LEAST(_x2 - _x1, _x1 + _map_size - _x2);
		END IF;
		IF _y1 > _y2 THEN
			_distance_y = LEAST(_y1 - _y2, _y2 + _map_size - _y1);
		ELSE
			_distance_y = LEAST(_y2 - _y1, _y1 + _map_size - _y2);
		END IF;
		INSERT INTO lkp_trader.PathsTime (ship, island_from, island_to, distance) VALUES (_ship, _island_from, _island_to, floor((_distance_x + _distance_y)/_speed/70)*70+70);
	END LOOP;
END
$$ LANGUAGE plpgsql;


CREATE PROCEDURE think(player_id INTEGER) LANGUAGE PLPGSQL AS $$
DECLARE
	_time DOUBLE PRECISION;
	_offer INTEGER;
	_ship INTEGER;
	_item INTEGER;
	_item_to_buy INTEGER;
	_item_to_sell INTEGER;
	_quantity DOUBLE PRECISION;
	_quantity_to_buy DOUBLE PRECISION;
	_quantity_to_sell DOUBLE PRECISION;
	_island_on integer;
	_island_to INTEGER;
	_island_from INTEGER;
	_customer INTEGER;
	_vendor INTEGER;
	_available DOUBLE PRECISION;
	_skip BOOLEAN;
	_need_extra_turn BOOLEAN;
	_distance_to DOUBLE PRECISION;
	_distance_between DOUBLE PRECISION;
BEGIN
	SELECT world.global.game_time INTO _time FROM world.global;
--
--
--
-- Планирование покупок в первый раз
--
	IF _time = 0 THEN
		FOR _ship, _island_on, _available IN
		SELECT world.ships.id, parked_ships.island, world.ships.capacity
		FROM world.ships
		INNER JOIN world.parked_ships ON world.ships.id=world.parked_ships.ship and world.ships.player=player_id
		LOOP
			SELECT vendor.id, customer.id, vendor.quantity , customer.quantity, vendor.island, vendor.item, customer.island
			INTO   _vendor  , _customer  , _quantity_to_buy, _quantity_to_sell, _island_from , _item      , _island_to
			FROM world.contractors AS vendor
			INNER JOIN world.contractors AS customer ON vendor.type = 'vendor' AND customer.type = 'customer' AND vendor.item = customer.item 
			WHERE customer.price_per_unit > vendor.price_per_unit
			ORDER BY (customer.price_per_unit - vendor.price_per_unit)*LEAST(_available, vendor.quantity)*(CASE WHEN _island_on = vendor.island THEN 1.2 ELSE 1 END) DESC limit 1;
			IF FOUND THEN
				_quantity := LEAST (_available, _quantity_to_buy);
				INSERT INTO actions.offers(contractor, quantity) VALUES(_vendor, _quantity) RETURNING id INTO _offer;
				INSERT INTO lkp_trader.tasks VALUES(_offer, _ship, _item, _available, _quantity, _customer, _island_from, _island_to);
				UPDATE world.contractors SET quantity = quantity - _quantity WHERE id = _vendor;
				IF (_island_on = _island_from) THEN
					INSERT INTO actions.transfers VALUES(_ship, _item, _quantity, 'load');
				ELSE
					INSERT INTO actions.ship_moves VALUES(_ship, _island_from);
				END IF;
			END IF;
		END LOOP;
		--Как можно быстрее завершаем ход
		RETURN;	
	END IF;
--
	_need_extra_turn = false;
--
--
--
-- Инициализация таблицы расстояний
--
	SELECT id INTO _island_on FROM lkp_trader.PathsTime LIMIT 1;
	IF NOT FOUND THEN
		CALL initialize_world(player_id);
	END IF;
--
--
--
--	Отвергнутые предложения
--
	FOR _offer IN 
	SELECT offer FROM events.offer_rejected
	LOOP
		DELETE FROM lkp_trader.tasks where lkp_trader.tasks.offer = _offer;
	END LOOP;
--
--
--
-- ГРААЛЬ
--
	-- отправить на остров разгрузки загружаемые корабли
	FOR _ship, _island_to IN
		SELECT lkp_trader.tasks.ship, lkp_trader.tasks.island_to
		FROM world.transferring_ships INNER JOIN lkp_trader.tasks ON world.transferring_ships.ship = lkp_trader.tasks.ship and world.transferring_ships.island = lkp_trader.tasks.island_from
	LOOP
		INSERT INTO actions.ship_moves VALUES(_ship, _island_to); 
	END LOOP;
	-- разгрузить корабли, прибывающие на остров покупателей
	FOR _ship, _item, _quantity IN
		SELECT lkp_trader.tasks.ship, lkp_trader.tasks.item, lkp_trader.tasks.expected
		FROM world.moving_ships INNER JOIN lkp_trader.tasks ON world.moving_ships.ship = lkp_trader.tasks.ship and world.moving_ships.destination = lkp_trader.tasks.island_to
	LOOP
		INSERT INTO actions.transfers VALUES (_ship, _item, _quantity, 'unload');
	END LOOP;
	-- загрузить корабли, прибывающие на остров продавцов за товаром
	FOR _ship, _item, _quantity IN
		SELECT lkp_trader.tasks.ship, lkp_trader.tasks.item, lkp_trader.tasks.expected
		FROM world.moving_ships INNER JOIN lkp_trader.tasks ON world.moving_ships.ship = lkp_trader.tasks.ship and world.moving_ships.destination = lkp_trader.tasks.island_from
	LOOP
		INSERT INTO actions.transfers VALUES (_ship, _item, _quantity, 'load');
	END LOOP;
--
--
-- Передвинутые корабли
--
	FOR _ship, _item_to_sell, _quantity_to_sell, _item_to_buy, _quantity_to_buy, _offer, _available IN
		SELECT events.ship_move_finished.ship, world.cargo.item, world.cargo.quantity, lkp_trader.tasks.item, lkp_trader.tasks.capacity, lkp_trader.tasks.offer, world.storage.quantity
		FROM events.ship_move_finished 
		INNER JOIN world.parked_ships ON events.ship_move_finished.ship = world.parked_ships.ship
		LEFT JOIN world.cargo ON events.ship_move_finished.ship = world.cargo.ship
		LEFT JOIN lkp_trader.tasks ON events.ship_move_finished.ship = lkp_trader.tasks.ship
		LEFT JOIN world.storage ON world.storage.island = lkp_trader.tasks.island_from and world.storage.player = player_id and world.storage.item = lkp_trader.tasks.item
	LOOP
		IF _item_to_sell IS NOT NULL THEN	-- передвинутый корабль с грузом может быть только в остров назначения, значит сразу разгружаемся
			INSERT INTO actions.transfers VALUES (_ship, _item_to_sell, _quantity_to_sell, 'unload');
		ELSIF _available IS NOT NULL and _available > 0.1 THEN	--Есть товар под задачу, значит грузимся
			INSERT INTO actions.transfers VALUES(_ship, _item_to_buy, _available-0.000000001, 'load');
			UPDATE lkp_trader.tasks SET expected = _available-0.000000001 WHERE offer = _offer;
			_need_extra_turn = true;	-- вдруг проблема загрузки
		ELSIF _offer IS NOT NULL THEN	-- Есть задача, но товара на складе не оказалось (увез другой корабль)
			DELETE FROM lkp_trader.tasks WHERE lkp_trader.tasks.offer = _offer;
		END IF;
	END LOOP;
--
--
--
-- Погрузка / разгрузка кораблей
--
	FOR _ship, _island_on, _island_to, _offer IN 
	SELECT events.transfer_completed.ship, world.parked_ships.island, lkp_trader.tasks.island_to, lkp_trader.tasks.offer 
	FROM events.transfer_completed
	INNER JOIN world.parked_ships ON events.transfer_completed.ship = world.parked_ships.ship
	LEFT JOIN lkp_trader.tasks ON events.transfer_completed.ship = lkp_trader.tasks.ship
	LOOP
		IF _offer IS NULL THEN
			-- произошла загрузка корабля без задачи (загрузился под удалённую задачу)
			-- выбираем покупателя с максимальной ценой и отправляем корабль туда.
			SELECT 	world.contractors.island into _island_from
			FROM world.cargo 
			INNER JOIN world.contractors ON world.cargo.item = world.contractors.item and world.contractors.type = 'customer' and world.cargo.ship = _ship
			ORDER BY world.contractors.price_per_unit DESC LIMIT 1;
			IF FOUND THEN -- если корабль разгрузился без задачи, то запрос окажется пустым, поэтому проверяем на наличие ответа
				INSERT INTO actions.ship_moves VALUES(_ship, _island_from);
			END IF;
		ELSIF _island_on = _island_to THEN --разгрузился по задаче, удаляем задачу из списка
			DELETE FROM lkp_trader.tasks WHERE lkp_trader.tasks.offer = _offer;
		ELSE  -- загрузился по задаче, отправляем дальше по задаче
			INSERT INTO actions.ship_moves VALUES(_ship, _island_to);
		END IF;
	END LOOP;
--
--
-- Корабли, у которых возникла проблема загрузки
--
	FOR _ship, _item_to_buy, _quantity_to_buy, _offer, _available IN
	SELECT world.parked_ships.ship, lkp_trader.tasks.item, lkp_trader.tasks.capacity, lkp_trader.tasks.offer, world.storage.quantity
	FROM world.parked_ships 
	INNER JOIN lkp_trader.tasks ON world.parked_ships.ship = lkp_trader.tasks.ship
	LEFT JOIN world.storage ON world.storage.island = lkp_trader.tasks.island_from AND world.storage.player = player_id AND world.storage.item = lkp_trader.tasks.item
	LEFT JOIN actions.transfers ON world.parked_ships.ship = actions.transfers.ship
	LEFT JOIN actions.ship_moves ON world.parked_ships.ship = actions.ship_moves.ship
	WHERE actions.transfers.ship IS NULL and actions.ship_moves.ship IS NULL AND lkp_trader.tasks.offer > 0
	-- корабль с задачей, но без приказа, и код задачи не отрицательный (в конце боя кораблям, которые не успеют ничего доставить добавляются задачи с отрицательным кодом, чтоб на них не тратить ресурсы)
	LOOP
		IF _available IS NOT NULL AND _available > 0.1 THEN	-- на острове есть товар, значит грузимся
			INSERT INTO actions.transfers VALUES(_ship, _item_to_buy, _available, 'load');
			UPDATE lkp_trader.tasks SET expected = _available WHERE offer = _offer;
		ELSE -- нет товара (возможно кто-то увез), значит данную задачу удаляем. Корабль окажется как выполнивший предыдущую задачу (пойдёт процесс поиска новой задачи)
			DELETE FROM lkp_trader.tasks where lkp_trader.tasks.offer = _offer;
		END IF;
	END LOOP;
--
--
--
--	Продажа товаров
--
	_island_on = -1;
	FOR _customer, _item, _quantity_to_sell, _quantity, _island_to, _skip IN 
		SELECT world.contractors.id, world.contractors.item, world.contractors.quantity, world.storage.quantity, world.contractors.island , world.contracts.contractor is not NULL 
		FROM world.storage -- собираем покупателей с островов, где есть мой товар
		INNER JOIN world.contractors ON world.storage.player = player_id AND world.storage.island = world.contractors.island AND world.storage.item = world.contractors.item
		AND world.contractors.type = 'customer'
		LEFT JOIN world.contracts on world.contractors.id = world.contracts.contractor and world.contracts.player = player_id
		ORDER BY world.contractors.island, world.contractors.price_per_unit DESC -- для каждого острова с приоритетом максивальной цены
	LOOP
		IF _island_on <> _island_to THEN -- для нового острова задаём количество товара на нём
			_island_on = _island_to;
			_available = _quantity;
		ELSIF _time < 99700 THEN -- если остров не новый и не конец боя, то пропускаем покупателей (нам надо продавать только тому, у кого цена максимальна)
			CONTINUE;
		END IF;
		IF _skip or _available < 0.0001 or _quantity_to_sell = 0 THEN -- если уже есть контракт с покупателем или количество товара слишком мало (погрешности округлений), то переходим к следующему
			CONTINUE;
		END IF;
		-- если можно продать меньше предложения покупателя, то продаем всё, что есть
		-- иначе если предложение покупателя меньше 150 (значит идёт активная продажа), то выставляем только на половину (надежда, что если противник тоже продаёт товар и его think отрабатывает чуть позже моего, то за время моего think предложение восстановится и я смогу сделать сделку)
		_quantity_to_buy = CASE WHEN _available < _quantity_to_sell THEN _available WHEN _quantity_to_sell < 150 THEN _quantity_to_sell / 2 ELSE _quantity_to_sell END;
		INSERT INTO actions.offers(contractor, quantity) VALUES(_customer, _quantity_to_buy) RETURNING id into _offer;
		_available = _available - _quantity_to_buy-0.0000001; --уменьшаем количество непроданного товара (с небольшой погрешностью, чтоб точно было остатков на складе)
	END LOOP;

	IF _time > 99700 THEN
		--в конце игры пытаемся создать контракты на максимум предложения у продавцов, которым я не собираюсь продавать. 
		-- может это немного "подгадит" противнику.
		FOR _customer, _item, _quantity_to_sell IN 
			SELECT world.contractors.id, world.contractors.item, world.contractors.quantity
			FROM world.contractors 
			LEFT JOIN world.storage ON world.storage.player = player_id AND world.storage.island = world.contractors.island AND world.storage.item = world.contractors.item
			AND world.contractors.type = 'customer'
			LEFT JOIN world.contracts ON world.contractors.id = world.contracts.contractor AND world.contracts.player = player_id
			LEFT JOIN lkp_trader.tasks  ON world.contractors.id = lkp_trader.tasks.customer 
			WHERE world.contractors.type = 'customer' AND world.contracts.contractor IS NULL AND lkp_trader.tasks.customer is NULL
		LOOP
			INSERT INTO actions.offers(contractor, quantity) VALUES(_customer, _quantity_to_sell) RETURNING id into _offer;
		END LOOP;
	END IF;
--
--
--	Покупка товаров
--
	FOR _ship, _island_on, _available IN
		SELECT world.ships.id, parked_ships.island, world.ships.capacity
		FROM world.ships
		INNER JOIN world.parked_ships ON world.ships.id=world.parked_ships.ship and world.ships.player=player_id
		LEFT JOIN lkp_trader.tasks ON world.ships.id = lkp_trader.tasks.ship
		WHERE lkp_trader.tasks.ship is null 
		ORDER BY world.ships.capacity DESC
	LOOP
		IF _time < 97500 - 2 * _available THEN 
			SELECT vendor.id, customer.id, vendor.quantity , customer.quantity, vendor.island, vendor.item, customer.island
			INTO   _vendor  , _customer  , _quantity_to_buy, _quantity_to_sell, _island_from , _item      , _island_to
			FROM world.contractors AS vendor
			INNER JOIN world.contractors AS customer ON vendor.type = 'vendor' AND customer.type = 'customer' and vendor.item = customer.item 
			LEFT JOIN lkp_trader.PathsTime AS between_islands ON between_islands.ship = _ship AND between_islands.island_from = vendor.island AND between_islands.island_to = customer.island
			LEFT JOIN lkp_trader.PathsTime AS to_island ON to_island.ship = _ship AND to_island.island_from = _island_on AND to_island.island_to = vendor.island
			LEFT JOIN world.storage ON customer.item = world.storage.item AND customer.island = world.storage.island AND world.storage.player = player_id
			LEFT JOIN (
				SELECT Sum(lkp_trader.tasks.expected) AS quantity_to_sell, lkp_trader.tasks.customer
				FROM lkp_trader.tasks GROUP BY lkp_trader.tasks.customer)
			AS items_to_sell ON customer.id = items_to_sell.customer 
			WHERE customer.price_per_unit > vendor.price_per_unit AND COALESCE(world.storage.quantity, 0) < GREATEST(250,customer.quantity) AND 2 * customer.quantity > COALESCE(items_to_sell.quantity_to_sell, 0)
			ORDER BY (customer.price_per_unit - vendor.price_per_unit)*LEAST(_available,vendor.quantity)/(LEAST(_available,vendor.quantity)*2+210+between_islands.distance+COALESCE(to_island.distance,-70)) DESC limit 1;
			IF FOUND THEN
				_quantity := LEAST (_available, _quantity_to_buy);
				INSERT INTO actions.offers(contractor, quantity) VALUES(_vendor, _quantity) RETURNING id INTO _offer;
				INSERT INTO lkp_trader.tasks values(_offer, _ship, _item, _available, _quantity, _customer, _island_from, _island_to);
				UPDATE world.contractors SET quantity = quantity - _quantity WHERE id = _vendor;
				IF (_island_on = _island_from) THEN
					INSERT INTO actions.transfers VALUES(_ship, _item, _quantity, 'load');
				ELSE
					INSERT INTO actions.ship_moves VALUES(_ship, _island_from);
				END IF;
			ELSE
				_need_extra_turn = true;
			END IF;
		ELSE --покупка с уточнением, чтоб успели доставить товар.
			SELECT vendor.id, customer.id, vendor.quantity, customer.quantity, vendor.island, vendor.item, customer.island, between_islands.distance, to_island.distance
			INTO   _vendor  , _customer  , _quantity_to_buy, _quantity_to_sell, _island_from , _item      , _island_to, _distance_between, _distance_to
			FROM world.contractors AS vendor
			INNER JOIN world.contractors AS customer ON vendor.type = 'vendor' AND customer.type = 'customer' and vendor.item = customer.item 
			LEFT JOIN lkp_trader.PathsTime AS between_islands ON between_islands.ship = _ship AND between_islands.island_from = vendor.island AND between_islands.island_to = customer.island
			LEFT JOIN lkp_trader.PathsTime AS to_island ON to_island.ship = _ship AND to_island.island_from = _island_on AND to_island.island_to = vendor.island
			LEFT JOIN lkp_trader.tasks ON customer.id = lkp_trader.tasks.customer
			WHERE customer.price_per_unit > vendor.price_per_unit and lkp_trader.tasks.customer is null --только среди покупателей, которым ещё не продаю
			ORDER BY (customer.price_per_unit - vendor.price_per_unit)*LEAST(_available, vendor.quantity, customer.quantity, (100000 - 490 - _time - coalesce(to_island.distance, -70) - coalesce(between_islands.distance, 0))/2 ) DESC limit 1;
			IF FOUND THEN
				_quantity := LEAST ((100000 - 490 - _time - coalesce(_distance_to, -70) - coalesce(_distance_between, 0))/2, _available, _quantity_to_buy, _quantity_to_sell);
				IF _quantity > 0 THEN
					INSERT INTO actions.offers(contractor, quantity) VALUES(_vendor, _quantity) RETURNING id INTO _offer;
					INSERT INTO lkp_trader.tasks values(_offer, _ship, _item, _available, _quantity, _customer, _island_from, _island_to);
					UPDATE world.contractors SET quantity = quantity - _quantity WHERE id = _vendor;
					IF (_island_on = _island_from) THEN
						INSERT INTO actions.transfers VALUES(_ship, _item, _quantity, 'load');
					ELSE
						INSERT INTO actions.ship_moves VALUES(_ship, _island_from);
					END IF;
				END IF;
			ELSE
				INSERT INTO lkp_trader.tasks values(-_ship, _ship, 1, 0, 0, 1, 1, 2); -- заглушка / мнимый приказ, чтобы не пытаться в конце по кораблю искать предложения, если их уже не было
			END IF;
		END IF;
	END LOOP;
--
--
--
-- если может быть проблема загрузки, то вызвать принудительно следующий think для новых приказов
--
	IF _need_extra_turn = true THEN
		INSERT INTO actions.wait(until) values(_time);
	END IF;
	
END $$;