import copy
import gc
import logging

import model
import numpy as np
import torch
import torch.nn as nn

from multiprocessing import pool, cpu_count

from model.MLM import BertForMaskedLM
from torch.utils.data import DataLoader
from tqdm.auto import tqdm
from collections import OrderedDict

from .models import *
from .utils import *
from .client import Client

logger = logging.getLogger(__name__)


class Server(object):
    """Class for implementing center server orchestrating the whole process of federated learning
    
    At first, center server distribute model skeleton to all participating clients with configurations.
    While proceeding federated learning rounds, the center server samples some fraction of clients,
    receives locally updated parameters, averages them as a global parameter (model), and apply them to global model.
    In the next round, newly selected clients will recevie the updated global model as its local model.  
    
    Attributes:
        clients: List containing Client instances participating a federated learning.
        __round: Int for indcating the current federated round.
        writer: SummaryWriter instance to track a metric and a loss of the global model.
        model: torch.nn instance for a global model.
        seed: Int for random seed.
        device: Training machine indicator (e.g. "cpu", "cuda").
        mp_flag: Boolean indicator of the usage of multiprocessing for "client_update" and "client_evaluate" methods.
        data_dir_path: Path to read data.
        dataset_name: Name of the dataset.
        num_shards: Number of shards for simulating non-IID data split (valid only when 'iid = False").
        iid: Boolean Indicator of how to split dataset (IID or non-IID).
        init_config: kwargs for the initialization of the model.
        fraction: Ratio for the number of clients selected in each federated round.
        num_clients: Total number of participating clients.
        local_epochs: Epochs required for client model update.
        batch_size: Batch size for updating/evaluating a client/global model.
        criterion: torch.nn instance for calculating loss.
        optimizer: torch.optim instance for updating parameters.
        optim_config: Kwargs provided for optimizer.
    """

    def __init__(self, model_config={}, global_config={}, data_config={}, init_config={}, fed_config={},
                 optim_config={}):
    # def __init__(self, writer, model_config={}, global_config={}, data_config={}, init_config={}, fed_config={},
    #              optim_config={}):
        self.clients = None
        self._round = 0
        # self.writer = writer
        self.vocab_pickle_path = data_config["vocab_pickle_path"]
        self.age_vocab_dict, _ = age_vocab(max_age=data_config["max_patient_age"])

        model_config['vocab_size'] = len(load_obj(self.vocab_pickle_path)['token2idx'].keys())
        model_config["age_vocab_size"] = len(self.age_vocab_dict.keys())

        self.model = eval(model_config["name"])(**model_config)

        self.seed = global_config["seed"]
        self.device = global_config["device"]
        self.mp_flag = global_config["is_mp"]
        self.output_model_path = global_config["output_model_path"]
        self.data_dir_path = data_config["data_dir_path"]
        self.dataset_name = data_config["dataset_name"]
        self.test_path = data_config["test_path"]
        # self.max_patient_age = data_config["max_patient_age"]
        self.max_len_seq = data_config["max_len_seq"]
        self.min_visit = data_config["min_visit"]

        self.init_config = init_config

        self.fraction = fed_config["C"]
        self.num_clients = fed_config["K"]
        self.num_rounds = fed_config["R"]
        self.local_epochs = fed_config["E"]
        self.batch_size = fed_config["B"]

        self.criterion = fed_config["criterion"]
        self.optimizer = fed_config["optimizer"]
        self.optim_config = optim_config

    def setup(self, **init_kwargs):
        """Set up all configuration for federated learning."""
        # valid only before the very first round
        assert self._round == 0

        # initialize weights of the model
        torch.manual_seed(self.seed)
        init_net(self.model, **self.init_config)

        message = f"[Round: {str(self._round).zfill(4)}] ...successfully initialized model (# parameters: {str(sum(p.numel() for p in self.model.parameters()))})!"
        print(message);
        # logging.info(message)
        del message;
        gc.collect()

        # split local dataset for each client
        local_datasets, test_dataset = create_datasets(self.data_dir_path, self.test_path, self.vocab_pickle_path,
                                                       self.age_vocab_dict, self.max_len_seq, self.min_visit)

        # assign dataset to each client
        self.clients = self.create_clients(local_datasets)

        # prepare hold-out dataset for evaluation
        self.data = test_dataset
        self.dataloader = DataLoader(test_dataset, batch_size=self.batch_size, shuffle=False)

        # configure detailed settings for client update and
        self.setup_clients(
            batch_size=self.batch_size,
            criterion=self.criterion, num_local_epochs=self.local_epochs,
            optimizer=self.optimizer, optim_config=self.optim_config
        )

        # send the model skeleton to all clients
        self.transmit_model()

    def create_clients(self, local_datasets):
        """Initialize each Client instance."""
        clients = []
        for k, dataset in tqdm(enumerate(local_datasets), leave=False):
            client = Client(client_id=k, local_data=dataset, device=self.device)
            clients.append(client)


        # Debugging message
        print(f"Number of clients created: {len(clients)}")
        if len(clients) != self.num_clients:
            raise ValueError(f"Number of created clients ({len(clients)}) does not match the expected number ({self.num_clients})")

        message = f"[Round: {str(self._round).zfill(4)}] ...successfully created all {str(self.num_clients)} clients!"
        print(message);
        # logging.info(message)
        del message;
        gc.collect()
        return clients

    def setup_clients(self, **client_config):
        """Set up each client."""
        for k, client in tqdm(enumerate(self.clients), leave=False):
            client.setup(**client_config)

        message = f"[Round: {str(self._round).zfill(4)}] ...successfully finished setup of all {str(self.num_clients)} clients!"
        print(message);
        # logging.info(message)
        del message;
        gc.collect()

    def transmit_model(self, sampled_client_indices=None):
        """Send the updated global model to selected/all clients."""
        if sampled_client_indices is None:
            # send the global model to all clients before the very first and after the last federated round
            assert (self._round == 0) or (self._round == self.num_rounds)

            for client in tqdm(self.clients, leave=False):
                client.model = copy.deepcopy(self.model)

            message = f"[Round: {str(self._round).zfill(4)}] ...successfully transmitted models to all {str(self.num_clients)} clients!"
            print(message);
            # logging.info(message)
            del message;
            gc.collect()
        else:
            # send the global model to selected clients
            assert self._round != 0

            for idx in tqdm(sampled_client_indices, leave=False):
                if idx >= len(self.clients):
                    raise IndexError(f"Client index {idx} out of range. Total clients: {len(self.clients)}")
                self.clients[idx].model = copy.deepcopy(self.model)

            message = f"[Round: {str(self._round).zfill(4)}] ...successfully transmitted models to {str(len(sampled_client_indices))} selected clients!"
            print(message);
            # logging.info(message)
            del message;
            gc.collect()

    def sample_clients(self):
        """Select some fraction of all clients."""
        # sample clients randomly
        message = f"[Round: {str(self._round).zfill(4)}] Select clients...!"
        print(message);
        # logging.info(message)
        del message;
        gc.collect()

        num_sampled_clients = max(int(self.fraction * self.num_clients), 1)
        sampled_client_indices = sorted(
            np.random.choice(a=[i for i in range(self.num_clients)], size=num_sampled_clients, replace=False).tolist())

        return sampled_client_indices

    def update_selected_clients(self, sampled_client_indices):
        """Call "client_update" function of each selected client."""
        # update selected clients
        message = f"[Round: {str(self._round).zfill(4)}] Start updating selected {len(sampled_client_indices)} clients...!"
        print(message);
        # logging.info(message)
        del message;
        gc.collect()

        selected_total_size = 0
        for idx in tqdm(sampled_client_indices, leave=False):
            self.clients[idx].client_update()
            selected_total_size += len(self.clients[idx])

        message = f"[Round: {str(self._round).zfill(4)}] ...{len(sampled_client_indices)} clients are selected and updated (with total sample size: {str(selected_total_size)})!"
        print(message);
        # logging.info(message)
        del message;
        gc.collect()

        return selected_total_size

    def mp_update_selected_clients(self, selected_index):
        """Multiprocessing-applied version of "update_selected_clients" method."""
        # update selected clients
        message = f"[Round: {str(self._round).zfill(4)}] Start updating selected client {str(self.clients[selected_index].id).zfill(4)}...!"
        print(message, flush=True);
        # logging.info(message)
        del message;
        gc.collect()

        self.clients[selected_index].client_update()
        client_size = len(self.clients[selected_index])

        message = f"[Round: {str(self._round).zfill(4)}] ...client {str(self.clients[selected_index].id).zfill(4)} is selected and updated (with total sample size: {str(client_size)})!"
        print(message, flush=True);
        # logging.info(message)
        del message;
        gc.collect()

        return client_size

    def average_model(self, sampled_client_indices, coefficients):
        """Average the updated and transmitted parameters from each selected client."""
        message = f"[Round: {str(self._round).zfill(4)}] Aggregate updated weights of {len(sampled_client_indices)} clients...!"
        print(message);
        # logging.info(message)
        del message;
        gc.collect()

        averaged_weights = OrderedDict()
        for it, idx in tqdm(enumerate(sampled_client_indices), leave=False):
            local_weights = self.clients[idx].model.state_dict()
            for key in self.model.state_dict().keys():
                if it == 0:
                    averaged_weights[key] = coefficients[it] * local_weights[key]
                else:
                    averaged_weights[key] += coefficients[it] * local_weights[key]
        self.model.load_state_dict(averaged_weights)

        message = f"[Round: {str(self._round).zfill(4)}] ...updated weights of {len(sampled_client_indices)} clients are successfully averaged!"
        print(message)
        # logging.info(message)
        del message
        gc.collect()

    def evaluate_selected_models(self, sampled_client_indices):
        """Call "client_evaluate" function of each selected client."""
        message = f"[Round: {str(self._round).zfill(4)}] Evaluate selected {str(len(sampled_client_indices))} clients' models...!"
        print(message)
        # logging.info(message)
        del message
        gc.collect()

        for idx in sampled_client_indices:
            self.clients[idx].client_evaluate()

        message = f"[Round: {str(self._round).zfill(4)}] ...finished evaluation of {str(len(sampled_client_indices))} selected clients!"
        print(message)
        # logging.info(message)
        del message
        gc.collect()

    def mp_evaluate_selected_models(self, selected_index):
        """Multiprocessing-applied version of "evaluate_selected_models" method."""
        self.clients[selected_index].client_evaluate()
        return True

    def train_federated_model(self):
        """Do federated training."""
        # select pre-defined fraction of clients randomly
        sampled_client_indices = self.sample_clients()

        # send global model to the selected clients
        self.transmit_model(sampled_client_indices)

        # updated selected clients with local dataset
        if self.mp_flag:
            with pool.ThreadPool(processes=cpu_count() - 1) as workhorse:
                selected_total_size = workhorse.map(self.mp_update_selected_clients, sampled_client_indices)
            selected_total_size = sum(selected_total_size)
        else:
            selected_total_size = self.update_selected_clients(sampled_client_indices)

        # evaluate selected clients with local dataset (same as the one used for local update)
        if self.mp_flag:
            message = f"[Round: {str(self._round).zfill(4)}] Evaluate selected {str(len(sampled_client_indices))} clients' models...!"
            print(message)
            # logging.info(message)
            del message
            gc.collect()

            with pool.ThreadPool(processes=cpu_count() - 1) as workhorse:
                workhorse.map(self.mp_evaluate_selected_models, sampled_client_indices)
        else:
            self.evaluate_selected_models(sampled_client_indices)

        # calculate averaging coefficient of weights
        mixing_coefficients = [len(self.clients[idx]) / selected_total_size for idx in sampled_client_indices]

        # average each updated model parameters of the selected clients and update the global model
        self.average_model(sampled_client_indices, mixing_coefficients)

    def evaluate_global_model(self):
        """Evaluate the global model using the global holdout dataset (self.data)."""
        self.model.eval()
        self.model.to(self.device)
        batch_precision_results = []
        test_loss, correct = 0, 0

        with torch.no_grad():
            for step, batch in enumerate(self.dataloader):
                batch = tuple(t.to(self.device) for t in batch)
                age_ids, input_ids, posi_ids, segment_ids, attMask, masked_label = batch
                loss, pred, label = self.model(input_ids, age_ids, segment_ids, posi_ids, attention_mask=attMask,
                                               masked_lm_labels=masked_label)
                unpadded_indexes = np.where(label.cpu().numpy() != -1)[0]
                if len(unpadded_indexes) == 0:
                    continue
                test_loss += loss
                # predicted = pred.argmax(dim=1, keepdim=True) # TODO SHOULD BE CHANGED FOR MULTI-LABEL TASKS!
                # correct += predicted.eq(label.view_as(predicted)).sum().item()
                batch_precision_result = calc_acc(label, pred)
                batch_precision_results.append(batch_precision_result)

                if self.device == "cuda": torch.cuda.empty_cache()
        self.model.to("cpu")

        test_loss = test_loss / len(self.dataloader)
        print(f'server test_loss={test_loss}, len(self.dataloader)={len(self.dataloader)}, test_loss={test_loss}')
        test_accuracy = sum(batch_precision_results) / len(batch_precision_results)
        return test_loss, test_accuracy  # todo: concat tensors on gpu device

    # def fit(self):
    #     """Execute the whole process of the federated learning."""
    #     best_result = 0
    #     self.results = {"loss": [], "accuracy": []}
    #     for r in range(self.num_rounds):
    #         self._round = r + 1

    #         self.train_federated_model()
    #         test_loss, test_accuracy = self.evaluate_global_model()

    #         self.results['loss'].append(test_loss)
    #         self.results['accuracy'].append(test_accuracy)

    #         # self.writer.add_scalars(
    #         #     'Loss',
    #         #     {
    #         #         f"[{self.dataset_name}]_{self.model.name} C_{self.fraction}, E_{self.local_epochs}, B_{self.batch_size}": test_loss},
    #         #     self._round
    #         # )
    #         # self.writer.add_scalars(
    #         #     'Accuracy',
    #         #     {
    #         #         f"[{self.dataset_name}]_{self.model.name} C_{self.fraction}, E_{self.local_epochs}, B_{self.batch_size}": test_accuracy},
    #         #     self._round
    #         # )

    #         message = f"[Round: {str(self._round).zfill(4)}] Evaluate global model's performance...!\
    #             \n\t[Server] ...finished evaluation!\
    #             \n\t=> Loss: {test_loss:.4f}\
    #             \n\t=> Accuracy: {100. * test_accuracy:.2f}%\n"
    #         print(message)
    #         # logging.info(message)
    #         del message
    #         gc.collect()
    #         if test_accuracy > best_result:
    #             best_result = test_accuracy
    #             print("** ** * Saving fine - tuned model ** ** * ")
    #             model_to_save = model.module if hasattr(self.model,
    #                                                     'module') else self.model  # Only save the model it-self
    #             torch.save(model_to_save.state_dict(), self.output_model_path)
    #             print("** ** * DONE Saving fine - tuned model ** ** * ")
    #     self.transmit_model()


    from src.utils import save_metrics_plot  # ייבוא הפונקציה מקובץ utils

    def fit(self):
        """Execute the whole process of the federated learning."""
        best_result = 0
        self.results = {"loss": [], "accuracy": []}
        for r in range(self.num_rounds):
            self._round = r + 1

            self.train_federated_model()
            test_loss, test_accuracy = self.evaluate_global_model()

            self.results['loss'].append(test_loss)
            self.results['accuracy'].append(test_accuracy)

            message = f"[Round: {str(self._round).zfill(4)}] Evaluate global model's performance...!\
                \n\t[Server] ...finished evaluation!\
                \n\t=> Loss: {test_loss:.4f}\
                \n\t=> Accuracy: {100. * test_accuracy:.2f}%\n"
            print(message)
            gc.collect()

            if test_accuracy > best_result:
                best_result = test_accuracy
                print("** ** * Saving fine-tuned model ** ** * ")
                model_to_save = self.model.module if hasattr(self.model, 'module') else self.model
                torch.save(model_to_save.state_dict(), self.output_model_path)
                print("** ** * DONE Saving fine-tuned model ** ** * ")

        # שמירת גרפים בסיום כל הסבבים
        save_metrics_plot(self.results, 'server_federated_learning_metrics.png')

        self.transmit_model()

